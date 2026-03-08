// FineTune/Audio/DDC/DDCController.swift
// High-level DDC display enumeration, CoreAudio matching, and volume control

#if !APP_STORE

import AppKit
import AudioToolbox
import CoreGraphics
import IOKit
import os

@Observable
@MainActor
final class DDCController {
    /// Set of CoreAudio AudioDeviceIDs that are backed by DDC volume control
    private(set) var ddcBackedDevices: Set<AudioDeviceID> = []

    /// Whether the initial DDC probe has completed
    private(set) var probeCompleted: Bool = false

    /// Cached DDC volumes for each backed device (0-100)
    private(set) var cachedVolumes: [AudioDeviceID: Int] = [:]

    private var services: [AudioDeviceID: DDCService] = [:]
    private var deviceUIDs: [AudioDeviceID: String] = [:]  // For persistence keying
    private var debounceTimers: [AudioDeviceID: DispatchWorkItem] = [:]
    private var probeWorkItem: DispatchWorkItem?
    private nonisolated(unsafe) var displayChangeObserver: NSObjectProtocol?

    private let ddcQueue = DispatchQueue(label: "com.finetune.ddc", qos: .utility)
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DDCController")

    /// Callback when DDC probe completes (triggers device list refresh)
    var onProbeCompleted: (() -> Void)?

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    nonisolated deinit {
        if let obs = displayChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Lifecycle

    func start() {
        probe()
        setupDisplayChangeObserver()
    }

    func stop() {
        if let obs = displayChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            displayChangeObserver = nil
        }
        probeWorkItem?.cancel()
        probeWorkItem = nil
        for (_, item) in debounceTimers { item.cancel() }
        debounceTimers.removeAll()
    }

    // MARK: - Public API

    /// Whether this CoreAudio device has DDC volume control.
    func isDDCBacked(_ deviceID: AudioDeviceID) -> Bool {
        ddcBackedDevices.contains(deviceID)
    }

    /// Gets the cached DDC volume for a device (0-100), or nil if not DDC-backed.
    func getVolume(for deviceID: AudioDeviceID) -> Int? {
        cachedVolumes[deviceID]
    }

    /// Sets the DDC volume for a device (0-100). Debounced to avoid I2C bus spam.
    func setVolume(for deviceID: AudioDeviceID, to volume: Int) {
        let clamped = max(0, min(100, volume))
        cachedVolumes[deviceID] = clamped

        // Persist
        if let uid = deviceUIDs[deviceID] {
            settingsManager.setDDCVolume(for: uid, to: clamped)
        }

        // Debounce DDC write
        debounceTimers[deviceID]?.cancel()
        let service = services[deviceID]
        let item = DispatchWorkItem { [weak self] in
            do {
                try service?.setAudioVolume(clamped)
            } catch {
                self?.logger.error("DDC write failed for device \(deviceID): \(error)")
            }
        }
        debounceTimers[deviceID] = item
        ddcQueue.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }

    /// Software mute: saves current volume, sets to 0.
    func mute(for deviceID: AudioDeviceID) {
        guard let uid = deviceUIDs[deviceID] else { return }
        let currentVolume = cachedVolumes[deviceID] ?? 50
        if currentVolume > 0 {
            settingsManager.setDDCSavedVolume(for: uid, to: currentVolume)
        }
        settingsManager.setDDCMuteState(for: uid, to: true)
        // Flush immediately so pre-mute volume survives a crash
        settingsManager.flushSync()
        setVolume(for: deviceID, to: 0)
    }

    /// Software unmute: restores saved volume.
    func unmute(for deviceID: AudioDeviceID) {
        guard let uid = deviceUIDs[deviceID] else { return }
        let savedVolume = settingsManager.getDDCSavedVolume(for: uid) ?? 50
        settingsManager.setDDCMuteState(for: uid, to: false)
        setVolume(for: deviceID, to: savedVolume)
    }

    /// Returns software mute state.
    func isMuted(for deviceID: AudioDeviceID) -> Bool {
        guard let uid = deviceUIDs[deviceID] else { return false }
        return settingsManager.getDDCMuteState(for: uid)
    }

    // MARK: - Display Probing

    /// Probes for DDC-capable displays on a background queue, then matches to CoreAudio devices.
    private func probe() {
        // Cancel pending debounced DDC writes — services will be replaced by re-probe
        for (_, item) in debounceTimers { item.cancel() }
        debounceTimers.removeAll()

        // TODO(Swift 6): This closure captures @MainActor self and runs on ddcQueue.
        // Currently safe because accessed properties are nonisolated or dispatched
        // to @MainActor via Task { @MainActor in }.
        ddcQueue.async { [weak self] in
            guard let self else { return }

            // 1. Discover all DCPAVServiceProxy entries and create DDC services
            let discovered = DDCService.discoverServices()
            self.logger.info("DDC probe: found \(discovered.count) DCPAVServiceProxy entries")
            guard !discovered.isEmpty else {
                Task { @MainActor [weak self] in
                    self?.ddcBackedDevices = []
                    self?.services = [:]
                    self?.probeCompleted = true
                    self?.onProbeCompleted?()
                }
                return
            }

            // 2. Probe each service for audio volume support (VCP 0x62)
            var audioCapable: [(entry: io_service_t, service: DDCService, displayName: String)] = []
            for (index, (entry, service)) in discovered.enumerated() {
                let name = Self.getDisplayName(for: entry)
                self.logger.info("DDC probe: checking display \(index + 1) '\(name)' for VCP 0x62...")
                if service.supportsAudioVolume() {
                    audioCapable.append((entry: entry, service: service, displayName: name))
                    self.logger.info("DDC audio-capable display: '\(name)'")
                } else {
                    self.logger.info("DDC probe: '\(name)' does not support VCP 0x62")
                    IOObjectRelease(entry)
                }
            }

            guard !audioCapable.isEmpty else {
                self.logger.info("DDC probe: no audio-capable displays found")
                // Entries that failed supportsAudioVolume() were already released above
                Task { @MainActor [weak self] in
                    self?.ddcBackedDevices = []
                    self?.services = [:]
                    self?.probeCompleted = true
                    self?.onProbeCompleted?()
                }
                return
            }

            // 3. Get all CoreAudio output devices (candidates for DDC matching)
            let coreAudioDevices = self.getCoreAudioOutputDevices()
            for ca in coreAudioDevices {
                self.logger.info("DDC probe: CoreAudio candidate: '\(ca.name)' (uid: \(ca.uid))")
            }

            // 4. Match DDC displays to CoreAudio devices
            var matched: [AudioDeviceID: DDCService] = [:]
            var matchedUIDs: [AudioDeviceID: String] = [:]
            var volumes: [AudioDeviceID: Int] = [:]
            var matchedDDCIndices = Set<Int>()

            // 4a. First pass: match by name (fuzzy: case-insensitive, trimmed, substring)
            for caDevice in coreAudioDevices {
                for (i, ddcDisplay) in audioCapable.enumerated() where !matchedDDCIndices.contains(i) {
                    if Self.namesMatch(caDevice.name, ddcDisplay.displayName) {
                        matched[caDevice.id] = ddcDisplay.service
                        matchedUIDs[caDevice.id] = caDevice.uid
                        matchedDDCIndices.insert(i)

                        if let vol = try? ddcDisplay.service.getAudioVolume() {
                            volumes[caDevice.id] = vol.current
                        }

                        self.logger.info("Matched CoreAudio '\(caDevice.name)' → DDC '\(ddcDisplay.displayName)' (by name)")
                        break
                    }
                }
            }

            // 4b. Second pass: match unmatched DDC displays to display-transport CoreAudio devices
            //     (HDMI, DisplayPort, Thunderbolt — these are monitor connections)
            let displayTransports: Set<TransportType> = [.hdmi, .displayPort, .thunderbolt]
            let unmatchedDisplayDevices = coreAudioDevices.filter { ca in
                !matched.keys.contains(ca.id) && displayTransports.contains(ca.transport)
            }
            let unmatchedDDC = audioCapable.enumerated().filter { !matchedDDCIndices.contains($0.offset) }

            for (i, ddcDisplay) in unmatchedDDC {
                for caDevice in unmatchedDisplayDevices where !matched.keys.contains(caDevice.id) {
                    matched[caDevice.id] = ddcDisplay.service
                    matchedUIDs[caDevice.id] = caDevice.uid
                    matchedDDCIndices.insert(i)

                    if let vol = try? ddcDisplay.service.getAudioVolume() {
                        volumes[caDevice.id] = vol.current
                    }

                    self.logger.info("Matched CoreAudio '\(caDevice.name)' → DDC '\(ddcDisplay.displayName)' (by transport: \(caDevice.transport))")
                    break
                }
            }

            // Release IOKit entries
            for item in audioCapable {
                IOObjectRelease(item.entry)
            }

            // 5. Publish results on main thread
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.services = matched
                self.deviceUIDs = matchedUIDs
                self.ddcBackedDevices = Set(matched.keys)

                // Use persisted volumes if available, otherwise use read values
                for (deviceID, uid) in matchedUIDs {
                    if let savedVolume = self.settingsManager.getDDCVolume(for: uid) {
                        self.cachedVolumes[deviceID] = savedVolume
                        // Restore saved volume to the display
                        let service = matched[deviceID]
                        self.ddcQueue.async {
                            try? service?.setAudioVolume(savedVolume)
                        }
                    } else if let readVolume = volumes[deviceID] {
                        self.cachedVolumes[deviceID] = readVolume
                    }
                }

                self.logger.info("DDC probe complete: \(matched.count) display(s) matched")
                self.probeCompleted = true
                self.onProbeCompleted?()
            }
        }
    }

    // MARK: - CoreAudio Device Discovery

    private struct CoreAudioDeviceInfo: Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: TransportType
    }

    /// Gets all CoreAudio output devices as candidates for DDC matching.
    /// Includes devices both with and without CoreAudio volume control,
    /// since some monitors report having volume control that doesn't actually work.
    private nonisolated func getCoreAudioOutputDevices() -> [CoreAudioDeviceInfo] {
        guard let deviceIDs = try? AudioObjectID.readDeviceList() else { return [] }

        var results: [CoreAudioDeviceInfo] = []
        for deviceID in deviceIDs {
            guard !deviceID.isAggregateDevice(),
                  !deviceID.isVirtualDevice(),
                  deviceID.hasOutputStreams() else { continue }

            guard let uid = try? deviceID.readDeviceUID(),
                  let name = try? deviceID.readDeviceName() else { continue }

            results.append(CoreAudioDeviceInfo(id: deviceID, uid: uid, name: name, transport: deviceID.readTransportType()))
        }
        return results
    }

    // MARK: - Name Matching

    /// Fuzzy name matching: case-insensitive, trimmed, with substring fallback.
    /// CoreAudio device names and IOKit display names both come from EDID but may
    /// differ in casing, whitespace, or truncation.
    private nonisolated static func namesMatch(_ a: String, _ b: String) -> Bool {
        let normA = a.trimmingCharacters(in: .whitespaces).lowercased()
        let normB = b.trimmingCharacters(in: .whitespaces).lowercased()
        if normA == normB { return true }
        // Substring fallback: one contains the other
        if normA.contains(normB) || normB.contains(normA) { return true }
        return false
    }

    // MARK: - Display Name from IOKit

    /// Gets the display product name from the IORegistry entry or its parent framebuffer.
    private nonisolated static func getDisplayName(for entry: io_service_t) -> String {
        // Walk up to find a parent with display info
        var current = entry
        IOObjectRetain(current)

        // Try up to 10 levels of parents to find display info
        // `needsRelease` tracks whether `current` holds an unreleased io_service_t
        var needsRelease = true
        for _ in 0..<10 {
            if let name = displayNameFromEntry(current) {
                IOObjectRelease(current)
                return name
            }

            var next: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &next)
            IOObjectRelease(current)
            guard kr == kIOReturnSuccess else {
                needsRelease = false  // `current` was already released above
                break
            }
            current = next
        }

        // Release the final `current` if the loop exhausted all 10 levels
        if needsRelease {
            IOObjectRelease(current)
        }

        // No display name found in registry hierarchy
        return "External Display"
    }

    private nonisolated static func displayNameFromEntry(_ entry: io_service_t) -> String? {
        guard let info = IODisplayCreateInfoDictionary(entry, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any],
              let names = info[kDisplayProductName] as? [String: String],
              let name = names.values.first else {
            return nil
        }
        return name
    }

    // MARK: - Display Change Observer

    private func setupDisplayChangeObserver() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.probeWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.logger.debug("Display configuration changed, re-probing DDC (after delay)")
                    self?.probe()
                }
            }
            self.probeWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
        }
    }
}

#endif
