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
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")

    // MARK: - Input Device Lock State

    /// Track if WE initiated the input change (to avoid revert loop)
    private var didInitiateInputSwitch = false

    /// Track when an input device was last connected (to distinguish auto-switch from user action)
    private var lastInputDeviceConnectTime: Date?

    /// Grace period to detect automatic device switching after connection (2 seconds)
    private let autoSwitchGracePeriod: TimeInterval = 2.0

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    init(settingsManager: SettingsManager? = nil) {
        let manager = settingsManager ?? SettingsManager()
        self.settingsManager = manager
        self.volumeState = VolumeState(settingsManager: manager)
        self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor, settingsManager: manager)

        Task { @MainActor in
            processMonitor.start()
            deviceMonitor.start()

            // Start device volume monitor AFTER deviceMonitor.start() populates devices
            // This fixes the race condition where volumes were read before devices existed
            deviceVolumeMonitor.start()

            // Sync device volume changes to taps for VU meter accuracy
            // For multi-device output, we track the primary (clock source) device's volume
            deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
                guard let self else { return }
                guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
                for (_, tap) in self.taps {
                    // Update if this is the tap's primary device
                    if tap.currentDeviceUID == deviceUID {
                        tap.currentDeviceVolume = newVolume
                    }
                }
            }

            // Sync device mute changes to taps for VU meter accuracy
            deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
                guard let self else { return }
                guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
                for (_, tap) in self.taps {
                    // Update if this is the tap's primary device
                    if tap.currentDeviceUID == deviceUID {
                        tap.isDeviceMuted = isMuted
                    }
                }
            }

            processMonitor.onAppsChanged = { [weak self] _ in
                self?.cleanupStaleTaps()
                self?.applyPersistedSettings()
            }

            deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            }

            deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceConnected(deviceUID, name: deviceName)
            }

            deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
                self?.handleInputDeviceDisconnected(deviceUID)
            }

            deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
                self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
                self?.lastInputDeviceConnectTime = Date()
            }

            deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
                self?.handleDefaultDeviceChanged(newDefaultUID)
            }

            deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
                Task { @MainActor [weak self] in
                    self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
                }
            }

            applyPersistedSettings()

            // Restore locked input device if feature is enabled
            if manager.appSettings.lockInputDevice {
                restoreLockedInputDevice()
            }
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Pinned apps appear first (sorted alphabetically), then unpinned active apps (sorted alphabetically).
    var displayableApps: [DisplayableApp] {
        let activeApps = apps
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = settingsManager.getPinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }

        // Pinned active apps (sorted alphabetically)
        let pinnedActive = activeApps
            .filter { settingsManager.isPinned($0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        // Pinned inactive apps (sorted alphabetically)
        let pinnedInactive = pinnedInactiveInfos
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { DisplayableApp.pinnedInactive($0) }

        // Unpinned active apps (sorted alphabetically)
        let unpinnedActive = activeApps
            .filter { !settingsManager.isPinned($0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        return pinnedActive + pinnedInactive + unpinnedActive
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        let info = PinnedAppInfo(
            persistenceIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
        settingsManager.pinApp(app.persistenceIdentifier, info: info)
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        settingsManager.unpinApp(identifier)
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        settingsManager.isPinned(app.persistenceIdentifier)
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

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

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

    /// Explicit shutdown for app termination. Ensures all listeners are cleaned up.
    /// Call from applicationWillTerminate or equivalent lifecycle hook.
    /// Note: For menu bar apps, process exit cleans up resources anyway, so this is optional.
    func shutdown() {
        stop()
        deviceVolumeMonitor.stop()
        logger.info("AudioEngine shutdown complete")
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

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        if let deviceUID = deviceUID {
            // Explicit device selection - stop following default
            followsDefault.remove(app.id)
            guard appDeviceRouting[app.id] != deviceUID else { return }
            appDeviceRouting[app.id] = deviceUID
            settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)
        } else {
            // "System Audio" selected - follow default
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)

            // Route to current default (if available)
            guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                // No default available yet - routing will happen when default becomes available
                // via handleDefaultDeviceChanged callback
                logger.warning("No default device available for \(app.name), will route when available")
                return
            }
            guard appDeviceRouting[app.id] != defaultUID else { return }
            appDeviceRouting[app.id] = defaultUID
        }

        // Switch tap if needed
        guard let targetUID = appDeviceRouting[app.id] else { return }
        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: targetUID)
                    // Restore saved volume/mute state after device switch
                    tap.volume = self.volumeState.getVolume(for: app.id)
                    tap.isMuted = self.volumeState.getMute(for: app.id)
                    // Update device volume/mute for VU meter after switch
                    if let device = self.deviceMonitor.device(for: targetUID) {
                        tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    self.logger.debug("Switched \(app.name) to device: \(targetUID)")
                } catch {
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            ensureTapExists(for: app, deviceUID: targetUID)
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Returns true if the app follows system default device
    func isFollowingDefault(for app: AudioApp) -> Bool {
        followsDefault.contains(app.id)
    }

    // MARK: - Multi-Device Selection

    /// Gets the device selection mode for an app
    func getDeviceSelectionMode(for app: AudioApp) -> DeviceSelectionMode {
        volumeState.getDeviceSelectionMode(for: app.id)
    }

    /// Sets the device selection mode for an app.
    /// Triggers tap reconfiguration when mode changes.
    func setDeviceSelectionMode(for app: AudioApp, to mode: DeviceSelectionMode) {
        let previousMode = volumeState.getDeviceSelectionMode(for: app.id)
        volumeState.setDeviceSelectionMode(for: app.id, to: mode, identifier: app.persistenceIdentifier)

        guard previousMode != mode else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Gets the selected device UIDs for multi-mode
    func getSelectedDeviceUIDs(for app: AudioApp) -> Set<String> {
        volumeState.getSelectedDeviceUIDs(for: app.id)
    }

    /// Sets the selected device UIDs for multi-mode.
    /// Triggers tap reconfiguration when in multi mode.
    func setSelectedDeviceUIDs(for app: AudioApp, to uids: Set<String>) {
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        volumeState.setSelectedDeviceUIDs(for: app.id, to: uids, identifier: app.persistenceIdentifier)

        guard previousUIDs != uids,
              getDeviceSelectionMode(for: app) == .multi else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Updates tap configuration based on current mode and selected devices
    private func updateTapForCurrentMode(for app: AudioApp) async {
        let mode = getDeviceSelectionMode(for: app)

        let deviceUIDs: [String]
        switch mode {
        case .single:
            if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else if let deviceUID = appDeviceRouting[app.id] {
                deviceUIDs = [deviceUID]
            } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else {
                logger.warning("No device available for \(app.name) in single mode")
                return
            }

        case .multi:
            let selectedUIDs = getSelectedDeviceUIDs(for: app).sorted()
            if selectedUIDs.isEmpty {
                return
            }
            deviceUIDs = selectedUIDs
        }

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    try await tap.updateDevices(to: deviceUIDs)
                    tap.volume = volumeState.getVolume(for: app.id)
                    tap.isMuted = volumeState.getMute(for: app.id)
                    // Update device volume for VU meter (use primary device)
                    if let primaryUID = deviceUIDs.first,
                       let device = deviceMonitor.device(for: primaryUID) {
                        tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    logger.debug("Updated \(app.name) to \(deviceUIDs.count) device(s)")
                } catch {
                    logger.error("Failed to update devices for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            // No tap exists - create one
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
        }
    }

    /// Creates a tap with the specified device UIDs
    private func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String]) {
        guard !deviceUIDs.isEmpty else { return }

        let tap = ProcessTapController(app: app, targetDeviceUIDs: deviceUIDs, deviceMonitor: deviceMonitor)
        tap.volume = volumeState.getVolume(for: app.id)

        // Set initial device volume/mute for VU meter (use primary device)
        if let primaryUID = deviceUIDs.first,
           let device = deviceMonitor.device(for: primaryUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        }

        do {
            try tap.activate()
            taps[app.id] = tap

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)

            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    func applyPersistedSettings() {
        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume and mute state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)

            // Handle multi-device mode
            if mode == .multi {
                if let savedUIDs = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
                   !savedUIDs.isEmpty {
                    // Filter to currently available devices, maintaining deterministic order
                    let availableUIDs = savedUIDs.filter { deviceMonitor.device(for: $0) != nil }
                        .sorted()  // Deterministic ordering
                    if !availableUIDs.isEmpty {
                        logger.debug("Restoring multi-device mode for \(app.name) with \(availableUIDs.count) device(s)")
                        ensureTapWithDevices(for: app, deviceUIDs: availableUIDs)

                        // Mark as applied if tap created successfully
                        guard taps[app.id] != nil else { continue }
                        appliedPIDs.insert(app.id)

                        // Apply volume and mute
                        if let volume = savedVolume {
                            taps[app.id]?.volume = volume
                        }
                        if let muted = savedMute, muted {
                            taps[app.id]?.isMuted = true
                        }
                        continue  // Skip single-device path
                    }
                    // All saved devices unavailable - fall through to single-device mode
                    logger.debug("All multi-mode devices unavailable for \(app.name), falling back to single mode")
                }
            }

            // Single-device mode (or multi-mode fallback)
            let deviceUID: String
            if settingsManager.isFollowingDefault(for: app.persistenceIdentifier) {
                // App follows system default (new app or explicitly set to follow)
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device available for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) follows system default: \(deviceUID)")
            } else if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
                      deviceMonitor.device(for: savedDeviceUID) != nil {
                // Explicit device routing exists and device is available
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // Saved device temporarily unavailable: fall back to system default for now
                // Don't persist - keep original device preference for when it reconnects
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) device temporarily unavailable, using default: \(deviceUID)")
            }
            appDeviceRouting[app.id] = deviceUID

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
        // Get fallback device from DeviceVolumeMonitor's cached default (not direct Core Audio)
        // This ensures we use kAudioHardwarePropertyDefaultOutputDevice, not DefaultSystemOutputDevice
        let fallbackDevice: (uid: String, name: String)?
        if let defaultUID = deviceVolumeMonitor.defaultDeviceUID,
           let device = deviceMonitor.device(for: defaultUID) {
            fallbackDevice = (uid: defaultUID, name: device.name)
        } else if let firstDevice = deviceMonitor.outputDevices.first {
            fallbackDevice = (uid: firstDevice.uid, name: firstDevice.name)
        } else {
            fallbackDevice = nil
        }

        var affectedApps: [AudioApp] = []
        var singleModeTapsToSwitch: [(tap: ProcessTapController, fallbackUID: String)] = []
        var multiModeTapsToUpdate: [(tap: ProcessTapController, remainingUIDs: [String])] = []

        // Iterate over taps instead of apps - apps list may be empty if disconnected device
        // was the system default (CoreAudio removes app from process list when output disappears)
        for tap in taps.values {
            let app = tap.app
            let mode = getDeviceSelectionMode(for: app)

            // Check if this tap uses the disconnected device
            guard tap.currentDeviceUIDs.contains(deviceUID) else { continue }

            affectedApps.append(app)

            if mode == .multi && tap.currentDeviceUIDs.count > 1 {
                // Multi-device mode: remove disconnected device, keep others
                let remainingUIDs = tap.currentDeviceUIDs.filter { $0 != deviceUID }.sorted()
                if !remainingUIDs.isEmpty {
                    multiModeTapsToUpdate.append((tap: tap, remainingUIDs: remainingUIDs))
                    // Update in-memory selection to remove disconnected device (don't persist)
                    var currentSelection = volumeState.getSelectedDeviceUIDs(for: app.id)
                    currentSelection.remove(deviceUID)
                    volumeState.setSelectedDeviceUIDs(for: app.id, to: currentSelection, identifier: nil)
                    continue
                }
                // All devices gone in multi-mode, fall through to single-device fallback
            }

            // Single-device mode (or multi-mode with no remaining devices): switch to fallback
            if let fallback = fallbackDevice {
                appDeviceRouting[app.id] = fallback.uid
                // Set to follow default in-memory (UI shows "System Audio")
                // Don't persist - original device preference stays in settings for reconnection
                followsDefault.insert(app.id)
                singleModeTapsToSwitch.append((tap: tap, fallbackUID: fallback.uid))
            } else {
                logger.error("No fallback device available for \(app.name)")
            }
        }

        // Execute device switches
        if !singleModeTapsToSwitch.isEmpty || !multiModeTapsToUpdate.isEmpty {
            Task {
                // Handle single-mode switches
                for (tap, fallbackUID) in singleModeTapsToSwitch {
                    do {
                        try await tap.switchDevice(to: fallbackUID)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        try await tap.updateDevices(to: remainingUIDs)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            let fallbackName = fallbackDevice?.name ?? "none"
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) affected")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackName, affectedApps: affectedApps)
            }
        }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [ProcessTapController] = []

        // Iterate over taps for consistency with handleDeviceDisconnected
        for tap in taps.values {
            let app = tap.app

            // Skip apps that are PERSISTED as following default - they don't have explicit device preferences
            // Note: in-memory followsDefault may include temporarily displaced apps, so check persisted state
            guard !settingsManager.isFollowingDefault(for: app.persistenceIdentifier) else { continue }

            // Check if this app was pinned to the reconnected device (from persisted settings)
            let persistedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier)
            guard persistedUID == deviceUID else { continue }

            // App was pinned to this device - switch it back
            guard appDeviceRouting[app.id] != deviceUID else { continue }

            affectedApps.append(app)
            appDeviceRouting[app.id] = deviceUID
            // Remove from followsDefault since we're restoring explicit routing
            followsDefault.remove(app.id)
            tapsToSwitch.append(tap)
        }

        if !tapsToSwitch.isEmpty {
            Task {
                for tap in tapsToSwitch {
                    do {
                        try await tap.switchDevice(to: deviceUID)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        if let device = self.deviceMonitor.device(for: deviceUID) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }
    }

    private func showReconnectNotification(deviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Reconnected"
        content.body = "\"\(deviceName)\" is back. \(affectedApps.count) app(s) switched back."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-reconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
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

    /// Called when system default output device changes - switches apps that follow default
    private func handleDefaultDeviceChanged(_ newDefaultUID: String) {
        // Update routing for ALL apps following default (including those in grace period)
        // This ensures apps resuming during grace period get the correct device
        for pid in followsDefault {
            appDeviceRouting[pid] = newDefaultUID
        }

        // Collect taps to switch (only currently playing apps have taps)
        var tapsToSwitch: [(app: AudioApp, tap: ProcessTapController)] = []
        for app in apps {
            guard followsDefault.contains(app.id) else { continue }
            if let tap = taps[app.id] {
                tapsToSwitch.append((app, tap))
            }
        }

        // Switch taps asynchronously
        if !tapsToSwitch.isEmpty {
            Task {
                for (app, tap) in tapsToSwitch {
                    do {
                        try await tap.switchDevice(to: newDefaultUID)
                        tap.volume = self.volumeState.getVolume(for: app.id)
                        tap.isMuted = self.volumeState.getMute(for: app.id)
                        if let device = self.deviceMonitor.device(for: newDefaultUID) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                    } catch {
                        self.logger.error("Failed to switch \(app.name) to new default: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Notification (only for apps with active taps)
        let affectedApps = apps.filter { followsDefault.contains($0.id) }
        if !affectedApps.isEmpty {
            let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? "Default Output"
            logger.info("Default changed to \(deviceName), \(affectedApps.count) app(s) following")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDefaultChangedNotification(newDeviceName: deviceName, affectedApps: affectedApps)
            }
        }
    }

    private func showDefaultChangedNotification(newDeviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Default Audio Device Changed"
        content.body = "\(affectedApps.count) app(s) switched to \"\(newDeviceName)\""
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "default-device-changed",
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
                self.followsDefault.remove(pid)
                self.appliedPIDs.remove(pid)  // Allow re-initialization if app resumes
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses timing heuristic to distinguish auto-switch (from device connection) vs user action.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // If WE initiated this change, just reset flag and return
        if didInitiateInputSwitch {
            didInitiateInputSwitch = false
            return
        }

        // If lock is disabled, let system control input
        guard settingsManager.appSettings.lockInputDevice else { return }

        // Check if this change happened right after a device connection
        let isAutoSwitch = lastInputDeviceConnectTime.map {
            Date().timeIntervalSince($0) < autoSwitchGracePeriod
        } ?? false

        if isAutoSwitch {
            // This is likely an automatic switch triggered by device connection
            // Restore our locked device
            logger.info("Auto-switch detected after device connection, restoring locked input device")
            restoreLockedInputDevice()
        } else {
            // This is likely a user-initiated change (System Settings, another app, etc.)
            // Respect their choice and update our locked device
            logger.info("User changed input device to: \(newDefaultInputUID) - updating lock")
            settingsManager.setLockedInputDeviceUID(newDefaultInputUID)
        }
    }

    /// Restores the locked input device, or falls back to built-in mic if unavailable.
    private func restoreLockedInputDevice() {
        guard let lockedUID = settingsManager.lockedInputDeviceUID,
              let lockedDevice = deviceMonitor.inputDevice(for: lockedUID) else {
            // No locked device or it's unavailable - fall back to built-in
            lockToBuiltInMicrophone()
            return
        }

        // Don't restore if already on the locked device
        guard deviceVolumeMonitor.defaultInputDeviceUID != lockedUID else { return }

        logger.info("Restoring locked input device: \(lockedDevice.name)")
        didInitiateInputSwitch = true
        deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id)
    }

    /// Locks the input device to the built-in microphone.
    private func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        setLockedInputDevice(builtInMic)
    }

    /// Called when user explicitly selects an input device (via FineTune UI).
    /// Persists the choice and applies the change.
    func setLockedInputDevice(_ device: AudioDevice) {
        logger.info("User locked input device to: \(device.name)")

        // Persist the choice
        settingsManager.setLockedInputDeviceUID(device.uid)

        // Apply the change
        didInitiateInputSwitch = true
        deviceVolumeMonitor.setDefaultInputDevice(device.id)
    }

    /// Handles locked input device disconnect - falls back to built-in mic.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        // If the locked device disconnected, fall back to built-in mic
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        logger.info("Locked input device disconnected, falling back to built-in mic")
        lockToBuiltInMicrophone()
    }
}
