// FineTune/Audio/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@Observable
@MainActor
final class AudioEngine {
    let processMonitor = AudioProcessMonitor()
    let deviceMonitor = AudioDeviceMonitor()
    let deviceVolumeMonitor: DeviceVolumeMonitor
    let volumeState: VolumeState
    let settingsManager: SettingsManager

    private var taps: [pid_t: ProcessTapController] = [:]
    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    init(settingsManager: SettingsManager? = nil) {
        let manager = settingsManager ?? SettingsManager()
        self.settingsManager = manager
        self.volumeState = VolumeState(settingsManager: manager)
        self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor)

        Task { @MainActor in
            processMonitor.start()
            deviceMonitor.start()

            // Start device volume monitor AFTER deviceMonitor.start() populates devices
            // This fixes the race condition where volumes were read before devices existed
            deviceVolumeMonitor.start()

            // Sync device volume changes to taps for VU meter accuracy
            deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
                guard let self else { return }
                guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
                for (pid, tap) in self.taps {
                    if self.appDeviceRouting[pid] == deviceUID {
                        tap.currentDeviceVolume = newVolume
                    }
                }
            }

            // Sync device mute changes to taps for VU meter accuracy
            deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
                guard let self else { return }
                guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
                for (pid, tap) in self.taps {
                    if self.appDeviceRouting[pid] == deviceUID {
                        tap.isDeviceMuted = isMuted
                    }
                }
            }
            
            deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] deviceUID in
                self?.setDeviceForAllApps(deviceUID)
            }

            processMonitor.onAppsChanged = { [weak self] _ in
                self?.cleanupStaleTaps()
                self?.applyPersistedSettings()
            }

            deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            }
            
            applyPersistedSettings()
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    func start() {
        // Monitors have internal guards against double-starting
        processMonitor.start()
        deviceMonitor.start()
        applyPersistedSettings()
        logger.info("AudioEngine started")
    }

    func stop() {
        processMonitor.stop()
        deviceMonitor.stop()
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        logger.info("AudioEngine stopped")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        taps[app.id]?.volume = volume
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    func setDevice(for app: AudioApp, deviceUID: String) {
        guard appDeviceRouting[app.id] != deviceUID else { return }
        appDeviceRouting[app.id] = deviceUID
        settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: deviceUID)
                    // Restore saved volume/mute state after device switch
                    tap.volume = self.volumeState.getVolume(for: app.id)
                    tap.isMuted = self.volumeState.getMute(for: app.id)
                    // Update device volume/mute for VU meter after switch
                    if let device = self.deviceMonitor.device(for: deviceUID) {
                        tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    self.logger.debug("Switched \(app.name) to device: \(deviceUID)")
                } catch {
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
    }
    
    func setDeviceForAllApps(_ deviceUID: String) {
        apps.forEach { app in
            setDevice(for: app, deviceUID: deviceUID)
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    func applyPersistedSettings() {
        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }

            // Load saved device routing, or assign to current macOS default
            let deviceUID: String
            if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
               deviceMonitor.device(for: savedDeviceUID) != nil {
                // Saved device exists, use it
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // New app or saved device no longer exists: assign to current macOS default
                do {
                    deviceUID = try AudioDeviceID.readDefaultSystemOutputDeviceUID()
                    settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)
                    logger.debug("App \(app.name) assigned to default device: \(deviceUID)")
                } catch {
                    logger.error("Failed to get default device for \(app.name): \(error.localizedDescription)")
                    continue
                }
            }
            appDeviceRouting[app.id] = deviceUID

            // Load saved volume and mute state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if let volume = savedVolume {
                let displayPercent = Int(VolumeMapping.gainToSlider(volume) * 200)
                logger.debug("Applying saved volume \(displayPercent)% to \(app.name)")
                taps[app.id]?.volume = volume
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }

        let tap = ProcessTapController(app: app, targetDeviceUID: deviceUID, deviceMonitor: deviceMonitor)
        tap.volume = volumeState.getVolume(for: app.id)

        // Set initial device volume/mute for VU meter accuracy
        if let device = deviceMonitor.device(for: deviceUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        }

        do {
            try tap.activate()
            taps[app.id] = tap

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Get fallback device: macOS default, or first available device
        let fallbackDevice: (uid: String, name: String)
        do {
            let uid = try AudioDeviceID.readDefaultSystemOutputDeviceUID()
            let name = deviceMonitor.device(for: uid)?.name ?? "Default Output"
            fallbackDevice = (uid: uid, name: name)
        } catch {
            guard let firstDevice = deviceMonitor.outputDevices.first else {
                logger.error("No fallback device available")
                return
            }
            fallbackDevice = (uid: firstDevice.uid, name: firstDevice.name)
        }

        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [ProcessTapController] = []

        for app in apps {
            if appDeviceRouting[app.id] == deviceUID {
                affectedApps.append(app)
                appDeviceRouting[app.id] = fallbackDevice.uid
                settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: fallbackDevice.uid)

                if let tap = taps[app.id] {
                    tapsToSwitch.append(tap)
                }
            }
        }

        if !tapsToSwitch.isEmpty {
            Task {
                for tap in tapsToSwitch {
                    do {
                        try await tap.switchDevice(to: fallbackDevice.uid)
                        // Restore saved volume/mute state after device switch
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                    } catch {
                        logger.error("Failed to switch device for \(tap.app.name): \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) switched to \(fallbackDevice.name)")
            showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackDevice.name, affectedApps: affectedApps)
        }
    }

    private func showDisconnectNotification(deviceName: String, fallbackName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Disconnected"
        content.body = "\"\(deviceName)\" disconnected. \(affectedApps.count) app(s) switched to \(fallbackName)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-disconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel cleanup for PIDs that reappeared
        for pid in activePIDs {
            if let task = pendingCleanup.removeValue(forKey: pid) {
                task.cancel()
                logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
            }
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                // Double-check still stale
                let currentPIDs = Set(self.apps.map { $0.id })
                guard !currentPIDs.contains(pid) else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.debug("Cleaned up stale tap for PID \(pid)")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }
}
