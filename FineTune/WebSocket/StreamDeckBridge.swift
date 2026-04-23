// FineTune/WebSocket/StreamDeckBridge.swift
import AppKit
import os

@MainActor
final class StreamDeckBridge {

    // MARK: - Properties

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "StreamDeckBridge")

    private let audioEngine: AudioEngine
    private let server: WebSocketServer

    private var stateTimer: Timer?
    private var levelsTimer: Timer?

    /// Snapshot of the last broadcast state to avoid redundant sends.
    private var lastStateJSON: Data?

    private let encoder = JSONEncoder()

    /// Apps the bridge has seen while active. Keyed by persistenceIdentifier.
    /// Remembered so we can include them as inactive in state broadcasts with their persisted settings.
    private var knownApps: [String: KnownApp] = [:]

    private struct KnownApp {
        let name: String
        let icon: String // base64
    }

    // MARK: - Init

    init(audioEngine: AudioEngine, server: WebSocketServer) {
        self.audioEngine = audioEngine
        self.server = server
    }

    // MARK: - Lifecycle

    func start() {
        server.start()

        chainCallbacks()
        startStateTimer()
        setupCommandHandler()
        setupLevelsSubscription()

        // Send initial state once the server is ready
        broadcastState()

        logger.info("StreamDeckBridge started")
    }

    func stop() {
        stateTimer?.invalidate()
        stateTimer = nil
        levelsTimer?.invalidate()
        levelsTimer = nil
        server.stop()

        logger.info("StreamDeckBridge stopped")
    }

    // MARK: - Callback Chaining

    /// Chains onto existing AudioEngine / DeviceVolumeMonitor callbacks without replacing them.
    private func chainCallbacks() {
        // Process monitor: app list changes
        let originalAppsChanged = audioEngine.processMonitor.onAppsChanged
        audioEngine.processMonitor.onAppsChanged = { [weak self] apps in
            originalAppsChanged?(apps)
            self?.broadcastState()
        }

        // Device volume changes
        let originalVolumeChanged = audioEngine.deviceVolumeMonitor.onVolumeChanged
        audioEngine.deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, volume in
            originalVolumeChanged?(deviceID, volume)
            self?.broadcastState()
        }

        // Device mute changes
        let originalMuteChanged = audioEngine.deviceVolumeMonitor.onMuteChanged
        audioEngine.deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, muted in
            originalMuteChanged?(deviceID, muted)
            self?.broadcastState()
        }

        // Default device changes
        let originalDefaultChanged = audioEngine.deviceVolumeMonitor.onDefaultDeviceChanged
        audioEngine.deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] uid in
            originalDefaultChanged?(uid)
            self?.broadcastState()
        }
    }

    // MARK: - Periodic State Broadcast

    /// 0.5s timer catches per-app volume/mute changes that have no callback.
    private func startStateTimer() {
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastState()
            }
        }
    }

    // MARK: - Levels Subscription

    private func setupLevelsSubscription() {
        server.onLevelsSubscriptionChanged = { [weak self] hasSubscribers in
            if hasSubscribers {
                self?.startLevelsTimer()
            } else {
                self?.stopLevelsTimer()
            }
        }
    }

    private func startLevelsTimer() {
        guard levelsTimer == nil else { return }
        // ~30 fps for snappy level meters
        levelsTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastLevels()
            }
        }
        logger.debug("Levels timer started")
    }

    private func stopLevelsTimer() {
        levelsTimer?.invalidate()
        levelsTimer = nil
        logger.debug("Levels timer stopped")
    }

    // MARK: - Command Handling

    private func setupCommandHandler() {
        server.onCommand = { [weak self] command in
            self?.handleCommand(command)
        }
    }

    private func handleCommand(_ command: WebSocketCommand) {
        switch command {
        case .setVolume(let bundleId, let volume):
            let clamped = volume.clamped(to: 0...1)
            if let app = findApp(bundleId: bundleId) {
                audioEngine.setVolume(for: app, to: clamped)
            } else {
                // App not currently active — persist for next launch
                audioEngine.setVolumeForInactive(identifier: bundleId, to: clamped)
            }
            broadcastState()

        case .toggleMute(let bundleId):
            if let app = findApp(bundleId: bundleId) {
                let currentMute = audioEngine.getMute(for: app)
                audioEngine.setMute(for: app, to: !currentMute)
            } else {
                // App not currently active — toggle persisted mute
                let currentMute = audioEngine.getMuteForInactive(identifier: bundleId)
                audioEngine.setMuteForInactive(identifier: bundleId, to: !currentMute)
            }
            broadcastState()

        case .setMasterVolume(let volume):
            setMasterVolume(volume.clamped(to: 0...1))
            broadcastState()

        case .toggleMasterMute:
            toggleMasterMute()
            broadcastState()

        case .subscribeLevels, .unsubscribeLevels:
            // Handled by WebSocketServer directly
            break
        }
    }

    // MARK: - Master Volume / Mute

    private func setMasterVolume(_ volume: Float) {
        guard let monitor = audioEngine.deviceVolumeMonitor as? DeviceVolumeMonitor else {
            logger.warning("setMasterVolume: deviceVolumeMonitor is not concrete DeviceVolumeMonitor")
            return
        }
        let deviceID = monitor.defaultDeviceID
        guard deviceID != .unknown else {
            logger.warning("setMasterVolume: no default output device")
            return
        }
        monitor.setVolume(for: deviceID, to: volume)
    }

    private func toggleMasterMute() {
        guard let monitor = audioEngine.deviceVolumeMonitor as? DeviceVolumeMonitor else {
            logger.warning("toggleMasterMute: deviceVolumeMonitor is not concrete DeviceVolumeMonitor")
            return
        }
        let deviceID = monitor.defaultDeviceID
        guard deviceID != .unknown else {
            logger.warning("toggleMasterMute: no default output device")
            return
        }
        let currentMute = monitor.muteStates[deviceID] ?? false
        monitor.setMute(for: deviceID, to: !currentMute)
    }

    // MARK: - State Building

    private func broadcastState() {
        let message = buildStateMessage()
        let wsMessage = WebSocketMessage.state(message)

        // Deduplicate: skip broadcast if state hasn't changed
        if let data = try? encoder.encode(wsMessage) {
            if data == lastStateJSON { return }
            lastStateJSON = data
        }

        server.broadcast(wsMessage)
    }

    private func buildStateMessage() -> StateMessage {
        let activeApps = audioEngine.apps
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Build active app states and remember them
        let activeStates = activeApps.map { app -> AppState in
            let icon = iconToBase64(app.icon, size: 32)
            // Remember this app for when it goes inactive
            knownApps[app.persistenceIdentifier] = KnownApp(name: app.name, icon: icon)

            return AppState(
                bundleId: app.persistenceIdentifier,
                name: app.name,
                icon: icon,
                volume: audioEngine.getVolume(for: app),
                isMuted: audioEngine.getMute(for: app),
                boost: audioEngine.getBoost(for: app).rawValue,
                outputDeviceUID: audioEngine.getDeviceUID(for: app),
                isActive: true
            )
        }

        // Include previously-seen apps that are no longer active, with persisted settings
        let inactiveStates = knownApps
            .filter { !activeIdentifiers.contains($0.key) }
            .map { (identifier, known) -> AppState in
                AppState(
                    bundleId: identifier,
                    name: known.name,
                    icon: known.icon,
                    volume: audioEngine.getVolumeForInactive(identifier: identifier),
                    isMuted: audioEngine.getMuteForInactive(identifier: identifier),
                    boost: audioEngine.getBoostForInactive(identifier: identifier).rawValue,
                    outputDeviceUID: nil,
                    isActive: false
                )
            }

        let appStates = activeStates + inactiveStates

        let monitor = audioEngine.deviceVolumeMonitor

        // Master volume/mute from default output device
        var masterVolume: Float = 1.0
        var masterMuted = false
        if let concreteMonitor = monitor as? DeviceVolumeMonitor {
            let deviceID = concreteMonitor.defaultDeviceID
            if deviceID != .unknown {
                masterVolume = concreteMonitor.volumes[deviceID] ?? 1.0
                masterMuted = concreteMonitor.muteStates[deviceID] ?? false
            }
        }

        let devices = audioEngine.outputDevices.map { device in
            DeviceState(id: device.uid, name: device.name)
        }

        return StateMessage(
            apps: appStates,
            masterVolume: masterVolume,
            masterMuted: masterMuted,
            outputDevices: devices
        )
    }

    // MARK: - Levels Building

    private func broadcastLevels() {
        guard server.hasLevelsSubscribers else { return }

        let rawLevels = audioEngine.audioLevels
        var appLevels: [String: AudioLevel] = [:]

        for app in audioEngine.apps {
            let peak = rawLevels[app.id] ?? 0.0
            appLevels[app.persistenceIdentifier] = AudioLevel(peak: peak)
        }

        let message = LevelsMessage(apps: appLevels)
        server.broadcastLevels(.levels(message))
    }

    // MARK: - Helpers

    private func findApp(bundleId: String) -> AudioApp? {
        audioEngine.apps.first { $0.persistenceIdentifier == bundleId }
    }

    /// Resize an NSImage to the given size and return a base64-encoded PNG string.
    private func iconToBase64(_ image: NSImage, size: Int) -> String {
        let targetSize = NSSize(width: size, height: size)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return ""
        }

        return pngData.base64EncodedString()
    }
}
