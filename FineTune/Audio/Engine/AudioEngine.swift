// FineTune/Audio/Engine/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

struct SoftwareVolumeOutputOption: Identifiable, Equatable {
    let uid: String
    let name: String
    let isAvailable: Bool
    let isEnabled: Bool

    var id: String { uid }
}

@Observable
@MainActor
final class AudioEngine {
    let processMonitor: any AudioProcessMonitoring
    let deviceMonitor: any AudioDeviceProviding
    let bluetoothDeviceMonitor: BluetoothDeviceMonitor
    let deviceVolumeMonitor: any DeviceVolumeProviding
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    let autoEQProfileManager: AutoEQProfileManager
    let permission: AudioRecordingPermission

    let accessibilityPermission: AccessibilityPermission
    let mediaKeyManager: MediaKeyManager
    private let volumeHUD: VolumeHUDController

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    private var taps: [pid_t: any ProcessTapControlling] = [:]

    /// Factory for creating tap controllers. Overridable for testing.
    private let tapFactory: @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

    /// Closure to check if a device is alive. Overridable for testing.
    private let isAliveCheck: (AudioDeviceID) -> Bool

    /// One-shot HAL listeners for devices that were present but not alive during priority resolution.
    /// Keyed by AudioDeviceID. Each entry holds the device UID, listener block, and a timeout task.
    private var aliveWatchers: [AudioDeviceID: (uid: String, block: AudioObjectPropertyListenerBlock, timeout: Task<Void, Never>)] = [:]

    /// Number of pending alive watchers (exposed for testing).
    var pendingAliveWatcherCount: Int { aliveWatchers.count }

    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
    /// The last output default confirmed by FineTune (user change or programmatic switch).
    /// Used to restore after macOS auto-switches to a lower-priority device.
    private var lastConfirmedDefaultUID: String?
    /// Timestamp of the last auto-switch override. Used to distinguish rapid BT auto-switches
    /// (< 1s apart) from deliberate user changes (> 1s after last override).
    private var lastAutoSwitchOverrideTime: Date?
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var staleCleanupTask: Task<Void, Never>?  // Debounced cleanup scheduling
    private var healthMonitorTask: Task<Void, Never>?  // Periodic tap health monitor
    private var tapRecoveryCooldownUntil: [pid_t: Date] = [:]  // Prevents tap recreation thrashing
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")

    // MARK: - Priority State Machine

    /// Tracks whether we're waiting for macOS to potentially auto-switch after a device connect.
    private enum PriorityState {
        case stable
        case pendingAutoSwitch(connectedDeviceUID: String, timeoutTask: Task<Void, Never>)
    }

    private var outputPriorityState: PriorityState = .stable
    private var inputPriorityState: PriorityState = .stable

    /// Grace period for auto-switch detection (wired devices)
    private let autoSwitchGracePeriod: TimeInterval = 2.0

    /// Extended grace period for Bluetooth devices (firmware handshake takes longer)
    private let btAutoSwitchGracePeriod: TimeInterval = 5.0

    // MARK: - Echo Suppression

    private let outputEchoTracker = EchoTracker(label: "Output")
    private let inputEchoTracker = EchoTracker(label: "Input")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    /// Whether a device supports volume control via hardware (CoreAudio or DDC).
    /// Does NOT include software volume — use `hasVolumeControl(for:)` for UI gating.
    func hasHardwareVolumeControl(for deviceID: AudioDeviceID) -> Bool {
        #if !APP_STORE
        // During DDC probe, assume hardware control to avoid brief software-volume flicker
        if !ddcController.probeCompleted { return true }
        return deviceID.hasOutputVolumeControl() || ddcController.isDDCBacked(deviceID)
        #else
        return deviceID.hasOutputVolumeControl()
        #endif
    }

    /// Whether a device supports any volume control (hardware, DDC, or explicit software volume).
    /// When true, the device row shows a volume slider.
    func hasVolumeControl(for deviceID: AudioDeviceID) -> Bool {
        if let device = deviceMonitor.device(for: deviceID),
           usesSoftwareVolume(for: device) {
            return true
        }
        #if !APP_STORE
        // Before DDC probe completes, assume all devices have volume control
        // to avoid premature hiding of controls on monitors that may be DDC-backed
        if !ddcController.probeCompleted { return true }
        return deviceID.hasOutputVolumeControl() || ddcController.isDDCBacked(deviceID)
        #else
        return deviceID.hasOutputVolumeControl()
        #endif
    }

    /// Whether FineTune should use its software gain path for this output device.
    func usesSoftwareVolume(for device: AudioDevice) -> Bool {
        settingsManager.getSoftwareVolumeOverride(for: device.uid) ?? false
    }

    func setSoftwareVolumeEnabled(_ enabled: Bool, for device: AudioDevice) {
        settingsManager.noteOutputDevice(uid: device.uid, name: device.name)
        if enabled {
            if !settingsManager.hasStoredSoftwareVolume(for: device.uid) {
                settingsManager.setSoftwareVolume(for: device.uid, to: deviceVolumeMonitor.volumes[device.id] ?? 1.0)
            }
            if !settingsManager.hasStoredSoftwareMute(for: device.uid) {
                settingsManager.setSoftwareMute(for: device.uid, to: deviceVolumeMonitor.muteStates[device.id] ?? false)
            }
        }

        settingsManager.setSoftwareVolumeOverride(for: device.uid, to: enabled)
        propagateSoftwareVolume(to: device.uid)
        updateMediaKeyInterception()
    }

    func setSoftwareVolumeEnabled(_ enabled: Bool, forDeviceUID uid: String) {
        if let device = deviceMonitor.device(for: uid) {
            setSoftwareVolumeEnabled(enabled, for: device)
            return
        }

        if enabled {
            if !settingsManager.hasStoredSoftwareVolume(for: uid) {
                settingsManager.setSoftwareVolume(for: uid, to: 1.0)
            }
            if !settingsManager.hasStoredSoftwareMute(for: uid) {
                settingsManager.setSoftwareMute(for: uid, to: false)
            }
        }

        settingsManager.setSoftwareVolumeOverride(for: uid, to: enabled)
        propagateSoftwareVolume(to: uid)
        updateMediaKeyInterception()
    }

    func softwareVolumeOutputOptions() -> [SoftwareVolumeOutputOption] {
        for device in outputDevices {
            settingsManager.ensureDeviceInPriority(device.uid)
            settingsManager.noteOutputDevice(uid: device.uid, name: device.name)
        }

        let connectedByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
        return settingsManager.knownOutputDeviceUIDs.map { uid in
            let connected = connectedByUID[uid]
            return SoftwareVolumeOutputOption(
                uid: uid,
                name: connected?.name ?? settingsManager.outputDeviceName(for: uid) ?? uid,
                isAvailable: connected != nil,
                isEnabled: settingsManager.getSoftwareVolumeOverride(for: uid) ?? false
            )
        }
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    /// Output devices sorted by user-defined priority order.
    /// Devices in the priority list appear in that order; new/unknown devices are appended alphabetically.
    var prioritySortedOutputDevices: [AudioDevice] {
        let devices = outputDevices
        let priorityOrder = settingsManager.devicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Collect devices in priority order (skip stale UIDs)
        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        // Append new devices alphabetically
        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Input devices sorted by user-defined priority order.
    var prioritySortedInputDevices: [AudioDevice] {
        let devices = inputDevices
        let priorityOrder = settingsManager.inputDevicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Registers any output devices not yet in the priority list.
    /// Call this when devices change (not from computed properties).
    func registerNewDevicesInPriority() {
        for device in outputDevices {
            settingsManager.ensureDeviceInPriority(device.uid)
            settingsManager.noteOutputDevice(uid: device.uid, name: device.name)
        }
        for device in inputDevices {
            settingsManager.ensureInputDeviceInPriority(device.uid)
        }
    }

    /// Returns the highest-priority device that is both connected and alive.
    /// `isDeviceAlive()` is checked internally — callers never need to check separately.
    static func resolveHighestPriority(
        priorityOrder: [String],
        connectedDevices: [AudioDevice],
        excluding: String? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil
    ) -> AudioDevice? {
        let aliveCheck = isAlive ?? { $0.isDeviceAlive() }
        let connected = Dictionary(
            connectedDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for uid in priorityOrder {
            guard uid != excluding,
                  let device = connected[uid],
                  aliveCheck(device.id) else { continue }
            return device
        }
        // Fallback: any alive connected device not excluded
        return connectedDevices.first {
            $0.uid != excluding && aliveCheck($0.id)
        }
    }


    init(
        permission: AudioRecordingPermission? = nil,
        settingsManager: SettingsManager? = nil,
        autoEQProfileManager: AutoEQProfileManager? = nil,
        deviceProvider: (any AudioDeviceProviding)? = nil,
        processMonitor: (any AudioProcessMonitoring)? = nil,
        deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
        tapFactory: (@MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        startMonitorsAutomatically: Bool = true
    ) {
        self.permission = permission ?? AudioRecordingPermission()
        self.accessibilityPermission = AccessibilityPermission()
        self.mediaKeyManager = MediaKeyManager()
        self.volumeHUD = VolumeHUDController()
        let manager = settingsManager ?? SettingsManager()
        self.settingsManager = manager
        self.autoEQProfileManager = autoEQProfileManager ?? AutoEQProfileManager()
        self.volumeState = VolumeState(settingsManager: manager)
        self.isAliveCheck = isAlive ?? { $0.isDeviceAlive() }

        // If a custom deviceProvider is given, use it directly.
        // Otherwise create a real AudioDeviceMonitor (needed by DeviceVolumeMonitor and default tap factory).
        let realDeviceMonitor: AudioDeviceMonitor?
        if let provider = deviceProvider {
            realDeviceMonitor = provider as? AudioDeviceMonitor
            self.deviceMonitor = provider
        } else {
            let monitor = AudioDeviceMonitor()
            realDeviceMonitor = monitor
            self.deviceMonitor = monitor
        }
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.bluetoothDeviceMonitor = BluetoothDeviceMonitor()

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager, ddcController: ddc)
        }
        #else
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager)
        }
        #endif

        // Tap factory: use provided factory or default to ProcessTapController
        if let factory = tapFactory {
            self.tapFactory = factory
        } else {
            self.tapFactory = { app, deviceUIDs, preferredSource in
                if deviceUIDs.count == 1 {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUID: deviceUIDs[0],
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                } else {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUIDs: deviceUIDs,
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                }
            }
        }

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.restoreConfirmedDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.restoreLockedInputDevice()
        }

        // Wire callbacks — needed for both test and production mode
        wireCallbacks()

        if startMonitorsAutomatically {
            Task { @MainActor in
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                }
                self.deviceMonitor.start()
                self.bluetoothDeviceMonitor.start()

                #if !APP_STORE
                ddc.onProbeCompleted = { [weak self] in
                    self?.deviceVolumeMonitor.refreshAfterDDCProbe()
                    self?.updateMediaKeyInterception()
                }
                ddc.start()
                #endif

                // Start device volume monitor AFTER deviceMonitor.start() populates devices
                self.deviceVolumeMonitor.start()

                self.applyPersistedSettings()
                self.registerNewDevicesInPriority()
                // Seed the confirmed default from whatever macOS has at startup
                self.lastConfirmedDefaultUID = self.deviceVolumeMonitor.defaultDeviceUID
                if manager.appSettings.lockInputDevice {
                    self.restoreLockedInputDevice()
                }

                // Start media key tap if Super Volume Keys is enabled and permission already granted
                if manager.appSettings.superVolumeKeysEnabled && self.accessibilityPermission.isGranted {
                    self.mediaKeyManager.start()
                }
                self.updateMediaKeyInterception()
                self.observeAccessibilityPermission()
            }
        }

        // Start process monitor when permission is granted
        if startMonitorsAutomatically && permission?.status != .authorized {
            observePermissionGranted()
        }
    }

    private func observePermissionGranted() {
        withObservationTracking {
            _ = self.permission.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                    self.applyPersistedSettings()
                    self.startHealthMonitor()
                    self.logger.info("Audio capture authorized — process monitor started")
                } else {
                    self.observePermissionGranted()
                }
            }
        }
    }

    /// Watches for Accessibility permission being granted or revoked and syncs the media key tap.
    private func observeAccessibilityPermission() {
        withObservationTracking {
            _ = self.accessibilityPermission.isGranted
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.accessibilityPermission.isGranted {
                    // Permission granted (or re-granted after revocation)
                    if self.settingsManager.appSettings.superVolumeKeysEnabled,
                       !self.mediaKeyManager.isActive {
                        self.mediaKeyManager.start()
                        self.updateMediaKeyInterception()
                        self.logger.info("Accessibility permission granted — media key tap started")
                    }
                } else if self.mediaKeyManager.isActive {
                    // Permission revoked — stop the now-disabled tap so it can be recreated later
                    self.mediaKeyManager.stop()
                    self.logger.info("Accessibility permission revoked — media key tap stopped")
                }
                // Re-observe for future changes
                self.observeAccessibilityPermission()
            }
        }
    }

    /// Wire all event callbacks from monitors to AudioEngine handlers.
    private func wireCallbacks() {
        // Sync device volume changes to taps for VU meter accuracy
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                }
            }
        }

        deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.isDeviceMuted = isMuted
                }
            }
        }

        processMonitor.onAppsChanged = { [weak self] apps in
            self?.applyPersistedSettings()
            self?.scheduleStaleCleanup()
        }

        // Priority order closures — only for concrete AudioDeviceMonitor
        if let realMonitor = deviceMonitor as? AudioDeviceMonitor {
            realMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            realMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.refresh()
        }

        deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceConnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.notifyDeviceAppearedInCoreAudio()
        }

        deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
            self?.handleInputDeviceDisconnected(deviceUID)
        }

        deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
            self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
            self?.handleInputDeviceConnected(deviceUID, name: deviceName)
        }

        deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
            self?.handleDefaultDeviceChanged(newDefaultUID)
        }

        deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
            }
        }

        // Wire media key callbacks. CGEventTap runs on the main run loop (main thread),
        // so MainActor.assumeIsolated lets us call @MainActor methods synchronously.
        mediaKeyManager.onVolumeUp = { [weak self] in
            MainActor.assumeIsolated { self?.adjustSoftwareVolume(by: 1.0 / 16.0) }
        }
        mediaKeyManager.onVolumeDown = { [weak self] in
            MainActor.assumeIsolated { self?.adjustSoftwareVolume(by: -1.0 / 16.0) }
        }
        mediaKeyManager.onMuteToggle = { [weak self] in
            MainActor.assumeIsolated { self?.toggleSoftwareMute() }
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
            .filter { !settingsManager.isIgnored($0.persistenceIdentifier) }
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

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        settingsManager.isPinned(identifier)
    }

    // MARK: - Ignored Apps

    /// Hide an active app so FineTune ignores it entirely.
    func ignoreApp(_ app: AudioApp) {
        let info = IgnoredAppInfo(
            persistenceIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
        settingsManager.ignoreApp(app.persistenceIdentifier, info: info)

        // Tear down the live tap so audio returns to natural volume
        if let tap = taps.removeValue(forKey: app.id) {
            tap.invalidate()
        }
        appDeviceRouting.removeValue(forKey: app.id)
        followsDefault.remove(app.id)
        appliedPIDs.remove(app.id)
    }

    /// Unhide an app by its persistence identifier.
    /// Immediately creates a tap if the app is currently running.
    func unignoreApp(_ identifier: String) {
        settingsManager.unignoreApp(identifier)
        applyPersistedSettings()
    }

    /// Check if an identifier is hidden.
    func isIgnored(identifier: String) -> Bool {
        settingsManager.isIgnored(identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    /// Get volume for an inactive app by persistence identifier.
    func getVolumeForInactive(identifier: String) -> Float {
        settingsManager.getVolume(for: identifier) ?? 1.0
    }

    /// Set volume for an inactive app by persistence identifier.
    func setVolumeForInactive(identifier: String, to volume: Float) {
        settingsManager.setVolume(for: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        settingsManager.getBoost(for: identifier) ?? .x1
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        settingsManager.setBoost(for: identifier, to: boost)
    }

    /// Get mute state for an inactive app by persistence identifier.
    func getMuteForInactive(identifier: String) -> Bool {
        settingsManager.getMute(for: identifier) ?? false
    }

    /// Set mute state for an inactive app by persistence identifier.
    func setMuteForInactive(identifier: String, to muted: Bool) {
        settingsManager.setMute(for: identifier, to: muted)
    }

    /// Get EQ settings for an inactive app by persistence identifier.
    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        settingsManager.getEQSettings(for: identifier)
    }

    /// Set EQ settings for an inactive app by persistence identifier.
    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        settingsManager.setEQSettings(settings, for: identifier)
    }

    /// Get device routing for an inactive app by persistence identifier.
    func getDeviceRoutingForInactive(identifier: String) -> String? {
        settingsManager.getDeviceRouting(for: identifier)
    }

    /// Set device routing for an inactive app by persistence identifier.
    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        if let deviceUID = deviceUID {
            settingsManager.setDeviceRouting(for: identifier, deviceUID: deviceUID)
        } else {
            settingsManager.setFollowDefault(for: identifier)
        }
    }

    /// Check if an inactive app follows system default device.
    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        settingsManager.isFollowingDefault(for: identifier)
    }

    /// Get device selection mode for an inactive app.
    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        settingsManager.getDeviceSelectionMode(for: identifier) ?? .single
    }

    /// Set device selection mode for an inactive app.
    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        settingsManager.setDeviceSelectionMode(for: identifier, to: mode)
    }

    /// Get selected device UIDs for an inactive app (multi-mode).
    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        settingsManager.getSelectedDeviceUIDs(for: identifier) ?? []
    }

    /// Set selected device UIDs for an inactive app (multi-mode).
    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        settingsManager.setSelectedDeviceUIDs(for: identifier, to: uids)
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
        if permission.status == .authorized {
            processMonitor.start()
        }
        deviceMonitor.start()
        applyPersistedSettings()
        if permission.status == .authorized {
            startHealthMonitor()
        }

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.info("AudioEngine started")
    }

    func stop() {
        stopHealthMonitor()
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

    // MARK: - Settings Reset

    /// Resets all persisted settings and synchronizes in-memory engine state.
    /// Active taps are kept alive but reverted to defaults (unity volume, unmuted, flat EQ).
    func handleSettingsReset() {
        // 1. Clear persisted state
        settingsManager.resetAllSettings()

        // Stop media key tap (superVolumeKeysEnabled is now false)
        mediaKeyManager.stop()
        updateMediaKeyInterception()

        // 2. Clear in-memory routing and tracking state
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        // 3. Clear cached per-app audio state
        volumeState.resetAll()

        // 4. Push defaults to all active taps
        let defaultVolume = settingsManager.appSettings.defaultNewAppVolume
        for tap in taps.values {
            tap.volume = defaultVolume
            tap.isMuted = false
            tap.updateEQSettings(.flat)
            tap.updateAutoEQProfile(nil)
        }

        // 5. Re-apply from clean settings (re-establishes routing to system default)
        applyPersistedSettings()

        logger.info("Settings reset: engine state synchronized")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        taps[app.id]?.volume = effectiveVolume(for: app.id)
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    // MARK: - Boost

    func setBoost(for app: AudioApp, to boost: BoostLevel) {
        volumeState.setBoost(for: app.id, to: boost, identifier: app.persistenceIdentifier)
        taps[app.id]?.volume = effectiveVolume(for: app.id)
    }

    func getBoost(for app: AudioApp) -> BoostLevel {
        volumeState.getBoost(for: app.id)
    }

    /// Effective gain for ProcessTapController: volume × boost × softwareVolume
    private func effectiveVolume(for pid: pid_t) -> Float {
        let appGain = volumeState.getVolume(for: pid) * volumeState.getBoost(for: pid).rawValue
        let deviceUID = appDeviceRouting[pid] ?? deviceVolumeMonitor.defaultDeviceUID ?? ""
        guard !deviceUID.isEmpty else { return appGain }
        guard usesSoftwareVolume(for: deviceUID) else { return appGain }
        if settingsManager.getSoftwareMute(for: deviceUID) { return 0 }
        return appGain * settingsManager.getSoftwareVolume(for: deviceUID)
    }

    // MARK: - Software Volume

    func getSoftwareVolume(for deviceUID: String) -> Float {
        settingsManager.getSoftwareVolume(for: deviceUID)
    }

    func setSoftwareVolume(for deviceUID: String, to volume: Float) {
        settingsManager.setSoftwareVolume(for: deviceUID, to: volume)
        propagateSoftwareVolume(to: deviceUID)
    }

    func getSoftwareMute(for deviceUID: String) -> Bool {
        settingsManager.getSoftwareMute(for: deviceUID)
    }

    func setSoftwareMute(for deviceUID: String, to muted: Bool) {
        settingsManager.setSoftwareMute(for: deviceUID, to: muted)
        propagateSoftwareVolume(to: deviceUID)
    }

    /// Re-applies effectiveVolume to all taps routed to a device, picking up software volume changes.
    private func propagateSoftwareVolume(to deviceUID: String) {
        for (pid, tap) in taps {
            let tapDevice = appDeviceRouting[pid] ?? deviceVolumeMonitor.defaultDeviceUID ?? ""
            guard tapDevice == deviceUID else { continue }
            tap.volume = effectiveVolume(for: pid)
        }
    }

    // MARK: - Super Volume Keys

    /// Called when the user presses Volume Up/Down via the media key interceptor.
    func adjustSoftwareVolume(by delta: Float) {
        guard let uid = deviceVolumeMonitor.defaultDeviceUID else { return }
        let current = settingsManager.getSoftwareVolume(for: uid)
        let clamped = max(0, min(1, current + delta))
        setSoftwareVolume(for: uid, to: clamped)
        volumeHUD.show(volume: clamped, isMuted: settingsManager.getSoftwareMute(for: uid))
    }

    /// Called when the user presses the Mute key via the media key interceptor.
    func toggleSoftwareMute() {
        guard let uid = deviceVolumeMonitor.defaultDeviceUID else { return }
        let newMuted = !settingsManager.getSoftwareMute(for: uid)
        setSoftwareMute(for: uid, to: newMuted)
        volumeHUD.show(volume: settingsManager.getSoftwareVolume(for: uid), isMuted: newMuted)
    }

    /// Enables or disables Super Volume Keys. Checks Accessibility permission and starts/stops the tap.
    func setSuperVolumeKeysEnabled(_ enabled: Bool) {
        if enabled {
            if accessibilityPermission.isGranted {
                mediaKeyManager.start()
            } else {
                // Add to the Accessibility list and prompt for permission
                accessibilityPermission.requestWithPrompt()
                // The tap will auto-start when the user grants permission (via didBecomeActiveNotification)
            }
        } else {
            mediaKeyManager.stop()
        }
        updateMediaKeyInterception()
    }

    /// Updates whether the media key tap should swallow volume events, based on current device state.
    func updateMediaKeyInterception() {
        guard settingsManager.appSettings.superVolumeKeysEnabled else {
            mediaKeyManager.shouldIntercept = false
            return
        }
        guard let uid = deviceVolumeMonitor.defaultDeviceUID,
              let device = deviceMonitor.device(for: uid) else {
            mediaKeyManager.shouldIntercept = false
            return
        }
        mediaKeyManager.shouldIntercept = usesSoftwareVolume(for: device)
    }

    private func usesSoftwareVolume(for deviceUID: String) -> Bool {
        guard let device = deviceMonitor.device(for: deviceUID) else {
            return settingsManager.getSoftwareVolumeOverride(for: deviceUID) ?? false
        }
        return usesSoftwareVolume(for: device)
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

    // MARK: - Per-Device AutoEQ

    func getAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    func setAutoEQProfile(for deviceUID: String, profileID: String?) {
        if let profileID {
            settingsManager.setAutoEQSelection(for: deviceUID, to: AutoEQSelection(profileID: profileID, isEnabled: true))
        } else {
            settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        }
        applyAutoEQToTaps(for: deviceUID)
    }

    func setAutoEQEnabled(for deviceUID: String, enabled: Bool) {
        guard var selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return }
        selection.isEnabled = enabled
        settingsManager.setAutoEQSelection(for: deviceUID, to: selection)
        applyAutoEQToTaps(for: deviceUID)
    }

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settingsManager.getAutoEQSelection(for: deviceUID)
    }

    var autoEQPreampEnabled: Bool {
        settingsManager.autoEQPreampEnabled
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsManager.autoEQPreampEnabled = enabled
        for tap in taps.values {
            tap.setAutoEQPreampEnabled(enabled)
        }
    }

    /// Apply AutoEQ profile to all taps currently routed to the given device.
    private func applyAutoEQToTaps(for deviceUID: String) {
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            applyAutoEQToTap(tap)
        }
    }

    /// Apply the correct AutoEQ profile to a single tap based on its current device.
    /// Skips AutoEQ entirely for devices that don't support it (speakers, HDMI, etc.).
    /// If the profile isn't loaded yet, triggers an async fetch and applies when ready.
    private func applyAutoEQToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }

        // Skip AutoEQ for non-headphone devices (or if device not found in monitor)
        guard let device = deviceMonitor.device(for: deviceUID) else {
            logger.debug("AutoEQ skip for \(tap.app.name): device \(deviceUID) not found in monitor")
            return
        }
        guard device.supportsAutoEQ else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): \(device.name) doesn't support AutoEQ")
            return
        }

        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID),
              selection.isEnabled else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): no selection or disabled for \(device.name)")
            return
        }

        // Try in-memory first (instant)
        if let profile = autoEQProfileManager.profile(for: selection.profileID) {
            tap.updateAutoEQProfile(profile)
            return
        }

        // Profile not loaded yet — fetch asynchronously
        tap.updateAutoEQProfile(nil)
        Task { @MainActor in
            guard let profile = await autoEQProfileManager.resolveProfile(for: selection.profileID) else { return }
            // Verify tap still exists and is still routed to the same device
            guard tap.currentDeviceUID == deviceUID else { return }
            tap.updateAutoEQProfile(profile)
        }
    }

    /// Sets the system default output device, routes followsDefault apps, and registers
    /// an echo so the resulting CoreAudio callback is consumed rather than treated as
    /// an external change.
    /// UI code should call this instead of `deviceVolumeMonitor.setDefaultDevice` directly.
    @discardableResult
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceVolumeMonitor.setDefaultDevice(deviceID) else { return false }
        if let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid {
            outputEchoTracker.increment(uid)
            lastConfirmedDefaultUID = uid
            routeFollowsDefaultApps(to: uid)
        }
        return true
    }

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        if let deviceUID = deviceUID {
            // Explicit device selection - stop following default
            followsDefault.remove(app.id)
            // Defensive: re-persist routing even if in-memory state matches,
            // to guard against settings file corruption or incomplete prior writes
            settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

            // If transitioning from follows-default to explicit and tap has a stream-specific
            // source, refresh to mixdown so it won't go stale when the default changes later.
            if let tap = taps[app.id], tap.tapSourceDeviceUID != nil {
                Task {
                    do {
                        try await tap.refreshTapSource(nil)
                        tap.volume = self.effectiveVolume(for: app.id)
                        tap.isMuted = self.volumeState.getMute(for: app.id)
                    } catch {
                        self.logger.error("Failed to refresh tap source for \(app.name): \(error)")
                    }
                }
            }

            guard appDeviceRouting[app.id] != deviceUID else { return }
            appDeviceRouting[app.id] = deviceUID
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
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: followsDefault.contains(app.id))
        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    // Restore saved volume/mute state after device switch
                    tap.volume = self.effectiveVolume(for: app.id)
                    tap.isMuted = self.volumeState.getMute(for: app.id)
                    // Update device volume/mute for VU meter after switch
                    if let device = self.deviceMonitor.device(for: targetUID) {
                        tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    self.applyAutoEQToTap(tap)
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
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    tap.volume = effectiveVolume(for: app.id)
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
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            tap.volume = effectiveVolume(for: app.id)

            // Set initial device volume/mute for VU meter (use primary device)
            if let primaryUID = deviceUIDs.first,
               let device = deviceMonitor.device(for: primaryUID) {
                tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
                tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
            }

            try tap.activate()
            taps[app.id] = tap

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)
            tap.setAutoEQPreampEnabled(settingsManager.autoEQPreampEnabled)
            applyAutoEQToTap(tap)

            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    func applyPersistedSettings() {
        guard permission.status == .authorized else { return }
        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }
            guard !settingsManager.isIgnored(app.persistenceIdentifier) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume, mute, and boost state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)
            _ = volumeState.loadSavedBoost(for: app.id, identifier: app.persistenceIdentifier)

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
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
                        appliedPIDs.insert(app.id)

                        // Apply volume (with boost) and mute
                        if savedVolume != nil {
                            taps[app.id]?.volume = effectiveVolume(for: app.id)
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

            // If a tap already exists but is on the wrong device (e.g., app reappeared
            // after the default changed while it was absent), switch it.
            if let existingTap = taps[app.id], existingTap.currentDeviceUIDs != [deviceUID] {
                let preferredSource = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
                Task {
                    do {
                        try await existingTap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredSource)
                        existingTap.volume = self.effectiveVolume(for: app.id)
                        existingTap.isMuted = self.volumeState.getMute(for: app.id)
                        if let device = self.deviceMonitor.device(for: deviceUID) {
                            existingTap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            existingTap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                        self.applyAutoEQToTap(existingTap)
                    } catch {
                        self.logger.error("Failed to re-route \(app.name) to \(deviceUID): \(error.localizedDescription)")
                    }
                }
                appliedPIDs.insert(app.id)
                continue
            }

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if savedVolume != nil {
                let effective = effectiveVolume(for: app.id)
                let displayPercent = Int(effective * 100)
                logger.debug("Applying saved volume \(displayPercent)% (with boost) to \(app.name)")
                taps[app.id]?.volume = effective
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, [deviceUID], preferredTapSourceUID)
            tap.volume = effectiveVolume(for: app.id)

            // Set initial device volume/mute for VU meter accuracy
            if let device = deviceMonitor.device(for: deviceUID) {
                tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
                tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
            }

            try tap.activate()
            taps[app.id] = tap

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)
            tap.setAutoEQPreampEnabled(settingsManager.autoEQPreampEnabled)
            applyAutoEQToTap(tap)

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Restores the default to `lastConfirmedDefaultUID` (what the user/FineTune intended).
    /// Falls back to highest-priority device if the confirmed device is gone.
    private func restoreConfirmedDefault() {
        if let restoreUID = lastConfirmedDefaultUID,
           let device = deviceMonitor.device(for: restoreUID),
           isAliveCheck(device.id) {
            if deviceVolumeMonitor.defaultDeviceUID != restoreUID {
                if deviceVolumeMonitor.setDefaultDevice(device.id) {
                    outputEchoTracker.increment(restoreUID)
                    logger.info("Restored default → \(device.name)")
                }
            }
            routeFollowsDefaultApps(to: restoreUID)
        } else {
            reEvaluateOutputDefault()
        }
    }

    /// Ensures system default matches highest-priority alive connected device.
    /// Routes followsDefault apps and switches their taps if default changes.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateOutputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if target.uid != currentDefault {
            if deviceVolumeMonitor.setDefaultDevice(target.id) {
                outputEchoTracker.increment(target.uid)
                logger.info("System default → \(target.name)")
            }
        }

        lastConfirmedDefaultUID = target.uid
        routeFollowsDefaultApps(to: target.uid)
        return target.uid
    }

    /// Ensures system default input matches highest-priority alive connected input device.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateInputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        if target.uid != deviceVolumeMonitor.defaultInputDeviceUID {
            if deviceVolumeMonitor.setDefaultInputDevice(target.id) {
                inputEchoTracker.increment(target.uid)
                logger.info("Default input → \(target.name)")
            }
        }
        return target.uid
    }

    /// Routes all followsDefault apps to the given device UID and switches their taps.
    /// Early-exits if all apps are already routed to the target (avoids unnecessary tap switches).
    private func routeFollowsDefaultApps(to targetUID: String) {
        guard !followsDefault.allSatisfy({ appDeviceRouting[$0] == targetUID }) else { return }

        for pid in followsDefault {
            appDeviceRouting[pid] = targetUID
        }

        var tapsToSwitch: [(app: AudioApp, tap: any ProcessTapControlling)] = []
        for app in apps {
            guard followsDefault.contains(app.id), let tap = taps[app.id] else { continue }
            tapsToSwitch.append((app, tap))
        }
        guard !tapsToSwitch.isEmpty else { return }

        Task {
            for (app, tap) in tapsToSwitch {
                do {
                    let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: true)
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    tap.volume = self.effectiveVolume(for: app.id)
                    tap.isMuted = self.volumeState.getMute(for: app.id)
                    if let device = self.deviceMonitor.device(for: targetUID) {
                        tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    self.applyAutoEQToTap(tap)
                } catch {
                    self.logger.error("Failed to switch \(app.name) to \(targetUID): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Clean up alive watcher — use UID lookup since device is already removed from monitor
        removeAliveWatcher(forUID: deviceUID)

        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = outputPriorityState, uid == deviceUID {
            task.cancel()
            outputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultOutput = deviceUID == deviceVolumeMonitor.defaultDeviceUID

        // Use priority-based fallback (resolve checks isDeviceAlive internally)
        let fallbackDevice = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        var affectedApps: [AudioApp] = []
        var singleModeTapsToSwitch: [(tap: any ProcessTapControlling, fallbackUID: String)] = []
        var multiModeTapsToUpdate: [(tap: any ProcessTapControlling, remainingUIDs: [String])] = []

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
                // Handle single-mode switches — source device is dead, skip crossfade
                for (tap, fallbackUID) in singleModeTapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [fallbackUID], isFollowsDefault: true)
                        try await tap.switchDevice(to: fallbackUID, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        tap.volume = self.effectiveVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                // Source device is dead, skip crossfade
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs, isFollowsDefault: self.followsDefault.contains(tap.app.id))
                        try await tap.updateDevices(to: remainingUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        tap.volume = self.effectiveVolume(for: tap.app.id)
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

        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID)
        }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        // Register newly connected device in priority list
        settingsManager.ensureDeviceInPriority(deviceUID)

        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [any ProcessTapControlling] = []

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
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: false)
                        try await tap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        tap.volume = self.effectiveVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        if let device = self.deviceMonitor.device(for: deviceUID) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Second pass: restore multi-device apps that had this device in their selection
        var multiModeTapsToUpdate: [any ProcessTapControlling] = []
        for tap in taps.values {
            let app = tap.app
            guard settingsManager.getDeviceSelectionMode(for: app.persistenceIdentifier) == .multi else { continue }
            guard let persistedUIDs = settingsManager.getSelectedDeviceUIDs(for: app.persistenceIdentifier),
                  persistedUIDs.contains(deviceUID) else { continue }
            let currentUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
            guard !currentUIDs.contains(deviceUID) else { continue }

            // Add the reconnected device back to in-memory selection
            var updatedUIDs = currentUIDs
            updatedUIDs.insert(deviceUID)
            volumeState.setSelectedDeviceUIDs(for: app.id, to: updatedUIDs, identifier: app.persistenceIdentifier)
            multiModeTapsToUpdate.append(tap)
        }

        if !multiModeTapsToUpdate.isEmpty {
            Task {
                for tap in multiModeTapsToUpdate {
                    await self.updateTapForCurrentMode(for: tap.app)
                }
            }
            logger.info("\(deviceName) reconnected, restored to \(multiModeTapsToUpdate.count) multi-device app(s)")
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }

        // Only override the default if the newly connected device IS the highest-priority
        // device (i.e., a higher-priority device just came back). If a lower-priority device
        // connects while the user is on a higher-priority device, respect the current default —
        // the user chose it. We still enter PENDING_AUTOSWITCH to guard against macOS
        // auto-switching to the new device.
        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        let isNewDeviceHigherPriority = (deviceUID == Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            isAlive: isAliveCheck
        )?.uid)

        // If this device is present but not alive, watch for it to become alive
        if let device = deviceMonitor.device(for: deviceUID),
           !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }

        if isNewDeviceHigherPriority, deviceUID != currentDefault {
            // A higher-priority device reconnected — switch to it
            reEvaluateOutputDefault()
        } else if !isNewDeviceHigherPriority, currentDefault == deviceUID {
            // macOS already auto-switched to the lower-priority device — restore
            // what the user was on (not highest priority — they may have chosen a mid-priority device)
            restoreConfirmedDefault()
        }

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one.
        if case .pendingAutoSwitch(_, let oldTask) = outputPriorityState {
            oldTask.cancel()
            outputPriorityState = .stable
        }

        // Always enter PENDING_AUTOSWITCH for the newly connected device.
        // macOS may auto-switch to it multiple times during BT firmware handshake.
        // Without this grace period, auto-switches would be treated as "genuine user change".
        let transport = deviceMonitor.device(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.outputPriorityState = .stable
            self.logger.debug("Auto-switch grace period expired, no macOS switch detected")
        }

        lastAutoSwitchOverrideTime = nil
        outputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
        logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")
    }

    // MARK: - Alive Watchers

    /// Installs a one-shot HAL listener for kAudioDevicePropertyDeviceIsAlive on a device
    /// that is present but not yet alive. When the device becomes alive, re-runs
    /// handleDeviceConnected so priority is re-evaluated. Self-removes after firing or timeout.
    private func installAliveWatcher(deviceID: AudioDeviceID, uid: String, name: String) {
        guard aliveWatchers[deviceID] == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAliveCheck(deviceID) else { return }
                self.logger.info("Device became alive: \(name) (\(uid)), re-evaluating priority")
                self.removeAliveWatcher(deviceID)
                self.handleDeviceConnected(uid, name: name)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            logger.warning("Failed to install alive watcher for \(name) (\(deviceID)): \(status)")
            return
        }

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.logger.debug("Alive watcher timed out for \(name) (\(uid))")
            self.removeAliveWatcher(deviceID)
        }

        aliveWatchers[deviceID] = (uid: uid, block: block, timeout: timeoutTask)
        logger.debug("Installed alive watcher for \(name) (\(uid))")
    }

    /// Removes a one-shot alive watcher by device ID, cleaning up the HAL listener and timeout.
    private func removeAliveWatcher(_ deviceID: AudioDeviceID) {
        guard let watcher = aliveWatchers.removeValue(forKey: deviceID) else { return }
        watcher.timeout.cancel()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, watcher.block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove alive watcher for device \(deviceID): \(status)")
        }
    }

    /// Removes a one-shot alive watcher by device UID. Used during disconnect when the
    /// device is already removed from the monitor's list and device(for:) returns nil.
    private func removeAliveWatcher(forUID uid: String) {
        guard let (deviceID, _) = aliveWatchers.first(where: { $0.value.uid == uid }) else { return }
        removeAliveWatcher(deviceID)
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
        // State machine: if we're waiting for macOS to auto-switch after a device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = outputPriorityState {
            // Check echoes FIRST — FineTune's own changes (UI, restoreConfirmedDefault)
            // create echoes. Consuming before Case 1 ensures FineTune UI changes aren't
            // mistaken for macOS auto-switches.
            if outputEchoTracker.consume(newDefaultUID) {
                return
            }

            if newDefaultUID == pendingUID {
                // Settling heuristic: if >1s since last override, BT auto-switches have
                // settled. This is likely the user changing via System Settings — accept it.
                // BT auto-switches happen within ms; user actions take >1s.
                if let lastOverride = lastAutoSwitchOverrideTime,
                   Date().timeIntervalSince(lastOverride) > 1.0 {
                    timeoutTask.cancel()
                    outputPriorityState = .stable
                    lastConfirmedDefaultUID = newDefaultUID
                    lastAutoSwitchOverrideTime = nil
                    routeFollowsDefaultApps(to: newDefaultUID)
                    let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? newDefaultUID
                    logger.info("Accepted user change to \(deviceName) (settled >1s)")
                    return
                }

                // Case 1: macOS auto-switched to the newly connected device — restore what
                // the user was on. Re-enter PENDING_AUTOSWITCH for further auto-switches.
                timeoutTask.cancel()
                restoreConfirmedDefault()
                lastAutoSwitchOverrideTime = Date()
                let transport = deviceMonitor.device(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.outputPriorityState = .stable
                    self.lastAutoSwitchOverrideTime = nil
                    self.logger.debug("Auto-switch grace period expired after override")
                }
                outputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }

            // Case 3: Genuine user intent (different device, not our echo) — respect it.
            timeoutTask.cancel()
            outputPriorityState = .stable
            lastAutoSwitchOverrideTime = nil
        }

        // Suppress echo from our own priority-based override (when not in pendingAutoSwitch)
        if outputEchoTracker.consume(newDefaultUID) {
            return
        }

        // If any echo counter is pending, another override is in flight — skip interim routing
        if outputEchoTracker.hasPending {
            logger.debug("Skipping followsDefault routing — echo pending")
            return
        }

        // Check if the new default device is known and alive.
        guard let newDevice = deviceMonitor.device(for: newDefaultUID) else {
            // Device not yet in monitor's list (e.g., BT device default-changed before device-list
            // notification). Defer — the upcoming handleDeviceConnected will enforce priority.
            logger.debug("Default changed to unknown device \(newDefaultUID), deferring to device list refresh")
            return
        }

        let newDeviceIsAlive = isAliveCheck(newDevice.id)

        if !newDeviceIsAlive {
            // Dead device became default (race with disconnect) — override to priority fallback
            reEvaluateOutputDefault()
        } else {
            // Genuine change to a live device — route followsDefault apps
            lastConfirmedDefaultUID = newDefaultUID
            routeFollowsDefaultApps(to: newDefaultUID)

            let affectedApps = apps.filter { followsDefault.contains($0.id) }
            if !affectedApps.isEmpty {
                let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? "Default Output"
                logger.info("Default changed to \(deviceName), \(affectedApps.count) app(s) following")
                if settingsManager.appSettings.showDeviceDisconnectAlerts {
                    showDefaultChangedNotification(newDeviceName: deviceName, affectedApps: affectedApps)
                }
            }
        }

        // Update media key interception for the new default device
        updateMediaKeyInterception()
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

    /// Returns the preferred tap source device UID for stream-specific capture.
    /// Only follows-default apps use stream-specific taps (multichannel preserved, tap always
    /// valid because the app switches device when default changes). Explicitly-routed apps
    /// always use stereo mixdown (nil) — their tap never goes stale when the default changes.
    private func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String], isFollowsDefault: Bool) -> String? {
        guard isFollowsDefault else { return nil }
        guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else { return nil }
        return outputUIDs.contains(defaultUID) ? defaultUID : nil
    }

    private func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel cleanup for PIDs that reappeared — but only if bundleID matches.
        // PID reuse by a different app should not rescue the old tap.

        for pid in activePIDs {
            guard let task = pendingCleanup[pid] else { continue }

            let reappearedApp = apps.first { $0.id == pid }
            let existingTap = taps[pid]

            if let reappearedApp, let existingTap,
               reappearedApp.bundleID != existingTap.app.bundleID {
                // PID was reused by a different app — let the old tap be destroyed
                logger.debug("PID \(pid) reused by different app (\(reappearedApp.bundleID ?? "nil") vs \(existingTap.app.bundleID ?? "nil")), not cancelling cleanup")
                continue
            }

            pendingCleanup.removeValue(forKey: pid)
            task.cancel()
            // Don't remove from appliedPIDs — the tap is still alive and the aggregate
            // device is still running. The process just transiently stopped audio I/O
            // during a device change (kAudioProcessPropertyIsRunning flicker).
            // Device routing is already handled by routeFollowsDefaultApps (follows-default)
            // or stays put (explicit routing). Re-processing would cause an unnecessary
            // crossfade that interrupts audio.
            logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
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

    /// Debounced stale tap cleanup — coalesces rapid app-list changes into a single cleanup pass.
    private func scheduleStaleCleanup() {
        staleCleanupTask?.cancel()
        staleCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.cleanupStaleTaps()
        }
    }

    // MARK: - Tap Health Monitor

    /// Starts a periodic health check that recreates unresponsive taps.
    /// Checks every 2 seconds; after 3 consecutive misses (~6s), the tap is presumed dead.
    private func startHealthMonitor() {
        guard healthMonitorTask == nil else { return }
        healthMonitorTask = Task { @MainActor [weak self] in
            var consecutiveMisses: [pid_t: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }

                // Skip entirely when no taps exist — avoids unnecessary work at idle (#176)
                guard !self.taps.isEmpty else { continue }

                let now = Date()

                for (pid, tap) in self.taps {
                    // Skip muted apps — no callbacks while muted isn't a health signal
                    guard !tap.isMuted else { continue }

                    // Skip PIDs in recovery cooldown to prevent recreation thrashing
                    if let cooldownEnd = self.tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                        continue
                    }

                    guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

                    // Only health-check apps that are actively streaming (isRunning=true).
                    // Paused apps have no callbacks, which is normal — not a health signal.
                    let isActivelyStreaming = self.processMonitor.activeApps.contains { $0.id == pid }
                    guard isActivelyStreaming else {
                        consecutiveMisses[pid] = 0
                        continue
                    }

                    if tap.hasRecentAudioCallback(within: 3.0) {
                        consecutiveMisses[pid] = 0
                    } else {
                        let misses = (consecutiveMisses[pid] ?? 0) + 1
                        consecutiveMisses[pid] = misses

                        if misses >= 3 {
                            self.logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                            consecutiveMisses[pid] = 0
                            await self.recreateTap(for: pid)
                        }
                    }
                }

                // Prune entries for PIDs no longer tracked
                consecutiveMisses = consecutiveMisses.filter { self.taps[$0.key] != nil }
                self.tapRecoveryCooldownUntil = self.tapRecoveryCooldownUntil.filter { self.taps[$0.key] != nil }
            }
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    private func recreateTap(for pid: pid_t) async {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        let deviceUIDs = oldTap.currentDeviceUIDs
        await oldTap.invalidateAsync()

        // Set cooldown to prevent thrashing
        tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(20)

        // Find the current AudioApp entry for this PID
        guard let app = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Re-route to the same device(s), preserving multi-device routing
        if deviceUIDs.count > 1 {
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
            if taps[app.id] != nil {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else if let deviceUID = deviceUIDs.first {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Mark as applied to avoid redundant re-processing in applyPersistedSettings
        if taps[pid] != nil {
            appliedPIDs.insert(pid)
        }

        // Restore mute state
        if let muted = volumeState.loadSavedMute(for: pid, identifier: app.persistenceIdentifier), muted {
            taps[pid]?.isMuted = true
        }
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses state machine to distinguish auto-switch (from device connection) vs user action.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after input device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = inputPriorityState {
            if newDefaultInputUID == pendingUID, settingsManager.appSettings.lockInputDevice {
                // Case 1: macOS auto-switched to the newly connected device — restore locked device.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times.
                timeoutTask.cancel()
                restoreLockedInputDevice()
                let transport = deviceMonitor.inputDevice(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.inputPriorityState = .stable
                    self.logger.debug("Input auto-switch grace period expired after override")
                }
                inputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }
            // Case 2: Our own echo from the override. Consume without disrupting state machine.
            if inputEchoTracker.consume(newDefaultInputUID) {
                return
            }
            // Case 3: Genuine user intent — respect it.
            timeoutTask.cancel()
            inputPriorityState = .stable
        }

        // Suppress echo from our own input device override (when not in pendingAutoSwitch)
        if inputEchoTracker.consume(newDefaultInputUID) {
            return
        }

        // If any input echo counter is pending, skip routing
        if inputEchoTracker.hasPending {
            logger.debug("Skipping input routing — echo pending")
            return
        }

        // If lock is disabled, let system control input freely
        guard settingsManager.appSettings.lockInputDevice else { return }

        // Restore the locked device — any change outside FineTune's UI is either
        // macOS auto-switch or System Settings, and the lock should hold either way.
        // Users change the lock via FineTune's UI (setLockedInputDevice).
        guard let lockedUID = settingsManager.lockedInputDeviceUID else { return }
        if newDefaultInputUID != lockedUID {
            restoreLockedInputDevice()
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
        if deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id) {
            inputEchoTracker.increment(lockedDevice.uid)
        }
    }

    /// Locks the input device to the built-in microphone.
    /// This is a fallback — does NOT update preferredInputDeviceUID.
    private func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        applyInputDeviceLock(builtInMic)
    }

    /// Applies input device lock without changing the user's preferred device.
    /// Used for fallback scenarios (disconnect, built-in mic recovery).
    private func applyInputDeviceLock(_ device: AudioDevice) {
        logger.info("Locking input device to: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when the user toggles lockInputDevice ON in settings.
    /// Captures the current default input device as the locked and preferred device.
    func handleInputLockEnabled() {
        guard let currentUID = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = deviceMonitor.inputDevice(for: currentUID) else {
            return
        }
        logger.info("Input lock enabled, locking to current default: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)
    }

    /// Called when user explicitly selects an input device (via FineTune UI).
    /// Persists the choice and applies the change.
    func setLockedInputDevice(_ device: AudioDevice) {
        logger.info("User locked input device to: \(device.name)")

        // Persist the choice — both current lock and preferred (user intent)
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)

        // Apply the change
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when an input device connects — restores locked/preferred device and guards against auto-switch.
    private func handleInputDeviceConnected(_ deviceUID: String, name deviceName: String) {
        guard settingsManager.appSettings.lockInputDevice else { return }

        // If the reconnected device is the user's preferred device, restore the lock to it
        if let preferredUID = settingsManager.preferredInputDeviceUID,
           deviceUID == preferredUID,
           settingsManager.lockedInputDeviceUID != preferredUID,
           let device = deviceMonitor.inputDevice(for: deviceUID) {
            logger.info("Preferred input device reconnected: \(deviceName), restoring lock")
            settingsManager.setLockedInputDeviceUID(device.uid)
        }

        // Restore the user's locked device (not priority-based — lock overrides priority)
        restoreLockedInputDevice()

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one
        if case .pendingAutoSwitch(_, let oldTask) = inputPriorityState {
            oldTask.cancel()
        }

        // Always enter PENDING_AUTOSWITCH — macOS may auto-switch to the newly connected
        // device multiple times during BT handshake, even if we just restored the lock.
        let transport = deviceMonitor.inputDevice(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.inputPriorityState = .stable
            self.logger.debug("Input auto-switch grace period expired, no macOS switch detected")
        }

        inputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
    }

    /// Handles input device disconnect — uses priority fallback, then built-in mic.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = inputPriorityState, uid == deviceUID {
            task.cancel()
            inputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultInput = deviceUID == deviceVolumeMonitor.defaultInputDeviceUID

        let priorityFallback = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }

        // If the locked device disconnected, update the lock to the fallback (or built-in mic)
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        if let fallbackDevice = priorityFallback {
            logger.info("Locked input device disconnected, falling back to priority: \(fallbackDevice.name)")
            if wasDefaultInput {
                // Default already switched above, just update the lock setting
                settingsManager.setLockedInputDeviceUID(fallbackDevice.uid)
            } else {
                applyInputDeviceLock(fallbackDevice)
            }
        } else {
            logger.info("Locked input device disconnected, falling back to built-in mic")
            lockToBuiltInMicrophone()
        }
    }
}

// MARK: - URLHandlerEngine Conformance

extension AudioEngine: URLHandlerEngine {}
