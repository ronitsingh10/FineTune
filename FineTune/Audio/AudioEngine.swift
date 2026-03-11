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

    // Global FX settings — stored property so @Observable tracks changes
    var fxSettings: FXSettings = FXSettings()
    // Master FX power toggle (applies to all FX processing regardless of device slot).
    var fxGlobalEnabled: Bool = true

    // Software volume/mute keyed by device UID — @Observable so the UI re-renders on change.
    // This is the single source of truth for display; DeviceVolumeMonitor.softwareVolumes
    // is a session-local AudioDeviceID cache used only by the audio render path.
    var softwareVolumesByUID: [String: Float] = [:]
    var softwareMutesByUID: [String: Bool] = [:]

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    /// Intercepts volume keys/knob and redirects to software gain for HDMI devices
    private var volumeKeyInterceptor: VolumeKeyInterceptor?

    private var taps: [pid_t: ProcessTapController] = [:]
    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
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

    /// Whether a device supports software volume control (CoreAudio or DDC).
    /// Devices without volume control still appear in the list but without slider/mute UI.
    func hasVolumeControl(for deviceID: AudioDeviceID) -> Bool {
        #if !APP_STORE
        // If the device already has native hardware volume, always true.
        if deviceID.hasOutputVolumeControl() { return true }
        // If probe hasn't finished yet, a monitor *might* still be DDC-backed — wait.
        if !ddcController.probeCompleted { return false }
        // Probe done: true only if DDC-backed.
        return ddcController.isDDCBacked(deviceID)
        #else
        return deviceID.hasOutputVolumeControl()
        #endif
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
        excluding: String? = nil
    ) -> AudioDevice? {
        let connected = Dictionary(
            connectedDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for uid in priorityOrder {
            guard uid != excluding,
                  let device = connected[uid],
                  device.id.isDeviceAlive() else { continue }
            return device
        }
        // Fallback: any alive connected device not excluded
        return connectedDevices.first {
            $0.uid != excluding && $0.id.isDeviceAlive()
        }
    }


    init(settingsManager: SettingsManager? = nil) {
        let manager = settingsManager ?? SettingsManager()
        self.settingsManager = manager
        self.volumeState = VolumeState(settingsManager: manager)

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor, settingsManager: manager, ddcController: ddc)
        #else
        self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor, settingsManager: manager)
        #endif

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.reEvaluateOutputDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.reEvaluateInputDefault()
        }

        Task { @MainActor in
            processMonitor.start()
            deviceMonitor.start()

            #if !APP_STORE
            ddc.onProbeCompleted = { [weak self] in
                self?.deviceVolumeMonitor.refreshAfterDDCProbe()
            }
            ddc.start()
            #endif

            // Load persisted software volumes BEFORE deviceVolumeMonitor.start() so
            // softwareVolumes is already seeded when the first SwiftUI render happens.
            // deviceMonitor.start() (above) populates outputDevices synchronously,
            // so this is safe to call here.
            deviceVolumeMonitor.loadSoftwareVolumes(from: manager, deviceMonitor: deviceMonitor)

            // Seed the UID-keyed observable dicts used by the UI
            for device in deviceMonitor.outputDevices {
                softwareVolumesByUID[device.uid] = manager.getSoftwareVolume(for: device.uid)
                softwareMutesByUID[device.uid] = manager.getSoftwareMute(for: device.uid)
            }

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

            // Propagate software gain changes to all taps handled by SoftwareGainStore directly

            // Seed SoftwareGainStore from persisted values so the render callback
            // immediately has the right gain even before any UI interaction.
            // Apply to ALL devices that have a stored software volume — this covers both
            // devices without hardware volume control AND devices where the user has set
            // a software volume override (SW badge), ensuring volumes are restored on relaunch.
            for device in deviceMonitor.outputDevices {
                let storedVol = manager.getSoftwareVolume(for: device.uid)
                let muted = manager.getSoftwareMute(for: device.uid)
                // Only apply if the device has no hardware control OR has an explicit saved volume
                let hasExplicitVolume = storedVol != 1.0 || muted
                if !device.id.hasOutputVolumeControl() || hasExplicitVolume {
                    SoftwareGainStore.setGain(muted ? 0.0 : storedVol, for: device.uid)
                }
            }

            // Seed fxSettings / fxEditingUID / fxSettingsForEditing from persisted values
            let savedEditingUID = manager.getFXEditingUID()
            fxEditingUID = savedEditingUID
            fxGlobalEnabled = manager.isFXGlobalEnabled()
            fxSettings = normalizedFXSettings(manager.getFXSettings(for: savedEditingUID))
            fxSettingsForEditing = normalizedFXSettings(manager.getFXSettings(for: savedEditingUID))

            processMonitor.onAppsChanged = { [weak self] _ in
                self?.cleanupStaleTaps()
                self?.applyPersistedSettings()
                self?.scheduleStaleCleanup()
            }

            deviceMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            deviceMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
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

            applyPersistedSettings()
            // Re-apply FX immediately after seeding taps so that system-FX is
            // pushed to every tap now that defaultDeviceUID is definitely known.
            applyFXToAllTaps()
            registerNewDevicesInPriority()
            // Restore locked input device if feature is enabled
            if manager.appSettings.lockInputDevice {
                restoreLockedInputDevice()
            }

            // Start volume key interceptor — redirects knob/F11/F12 to software gain
            // for HDMI devices that expose no hardware kAudioDevicePropertyVolumeScalar.
            // Uses CGEventTap (requires accessibility) to suppress the hollow system OSD;
            // falls back to NSEvent monitors if accessibility is not granted.
            let interceptor = VolumeKeyInterceptor(audioEngine: self)
            interceptor.start()
            self.volumeKeyInterceptor = interceptor

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

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        settingsManager.isPinned(identifier)
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

    /// Aggregated per-band spectrum levels across all active taps (0–1, 10 bands).
    /// Bands are log-spaced from ~56 Hz to ~10 kHz (FXSound filter design).
    var spectrumBandLevels: [Float] {
        let count = SpectrumBandAnalyzer.bandCount
        guard !taps.isEmpty else { return Array(repeating: 0, count: count) }
        let tapList = Array(taps.values)
        var result = Array(repeating: Float(0), count: count)
        for tap in tapList {
            let bands = tap.spectrumAnalyzer.snapshotBandLevels()
            guard bands.count == count else { continue }
            for i in 0..<count { result[i] = max(result[i], bands[i]) }
        }
        return result
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
        volumeKeyInterceptor?.stop()
        volumeKeyInterceptor = nil
        stop()
        deviceVolumeMonitor.stop()
        logger.info("AudioEngine shutdown complete")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID, useStreamSpecificTap: followsDefault.contains(app.id))
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
    // MARK: - FX Settings (per-device)

    /// The device UID currently being edited in the FX panel (nil = System Audio).
    /// Stored (not computed) so @Observable reliably tracks changes.
    var fxEditingUID: String? = nil

    /// FX settings for the currently editing device — what the panel displays.
    /// Stored (not computed) so @Observable reliably tracks changes.
    var fxSettingsForEditing: FXSettings = FXSettings()

    /// Per-device power is no longer used; normalize all persisted slots to enabled and
    /// use the global FX power toggle as the single source of on/off state.
    private func normalizedFXSettings(_ settings: FXSettings) -> FXSettings {
        var normalized = settings
        normalized.isEnabled = true
        return normalized
    }

    /// Save edited FX settings for the current editing target and re-apply to matching taps.
    /// In multi mode, writes to all selected device UIDs simultaneously.
    func setFXSettings(_ settings: FXSettings) {
        let normalized = normalizedFXSettings(settings)
        fxSettings = normalized   // keep observable var in sync for spectrum view
        fxSettingsForEditing = normalized  // keep FX panel state in sync when returning to tab
        if fxDeviceMode == .multi {
            // Apply the same settings to every selected device
            for uid in fxSelectedDeviceUIDs {
                settingsManager.setFXSettings(normalized, for: uid)
            }
        } else {
            settingsManager.setFXSettings(normalized, for: fxEditingUID)
        }
        applyFXToAllTaps()
    }

    /// Apply the correct per-device FX settings to every active tap.
    /// Each tap gets the settings for its own device UID; falls back to System Audio settings.
    func applyFXToAllTaps() {
        for (_, tap) in taps {
            tap.updateFXSettings(fxSettingsForTap(tap))
        }
    }

    /// Returns the FX settings that should be active on a given tap.
    /// Uses the first device UID that has its own persisted slot; falls back to System Audio.
    private func fxSettingsForTap(_ tap: ProcessTapController) -> FXSettings {
        let defaultUID = deviceVolumeMonitor.defaultDeviceUID
        let tapIsDefault = tap.currentDeviceUIDs.contains { $0 == defaultUID }

        // System Audio FX follows the default device — only apply it to that tap.
        let systemFX = tapIsDefault ? settingsManager.getFXSettings(for: nil) : nil

        // Per-device FX — keyed by the tap's specific device UID.
        var deviceFX: FXSettings? = nil
        for uid in tap.currentDeviceUIDs {
            if settingsManager.hasFXSettings(for: uid) {
                deviceFX = settingsManager.getFXSettings(for: uid)
                break
            }
        }
        let stacked: FXSettings
        switch (systemFX.map(normalizedFXSettings), deviceFX.map(normalizedFXSettings)) {
        case let (sys?, dev?): stacked = sys.stacked(with: dev)   // both layers
        case let (sys?, nil):  stacked = sys                       // system only
        case let (nil, dev?):  stacked = dev                       // device only
        case (nil, nil):       stacked = FXSettings()              // passthrough
        }
        var result = stacked
        result.isEnabled = result.isEnabled && fxGlobalEnabled
        return result
    }

    // MARK: - FX Device Routing

    var fxDeviceMode: DeviceSelectionMode { settingsManager.getFXDeviceMode() }
    var fxDeviceUID: String?              { settingsManager.getFXDeviceUID() }
    var fxSelectedDeviceUIDs: Set<String> { settingsManager.getFXSelectedDeviceUIDs() }
    var fxFollowsDefault: Bool            { settingsManager.isFXFollowingDefault() }

    /// Switch the editing target to a specific device and update routing.
    func setFXDevice(_ uid: String) {
        settingsManager.setFXEditingUID(uid)
        settingsManager.setFXDeviceUID(uid)
        settingsManager.setFXDeviceMode(.single)
        let s = normalizedFXSettings(settingsManager.getFXSettings(for: uid))
        fxEditingUID = uid
        fxSettings = s
        fxSettingsForEditing = s
        // Push the correct per-device + system layers to every tap now that the
        // editing target (and therefore the active device slot) has changed.
        applyFXToAllTaps()
    }

    /// Switch back to System Audio editing and routing.
    func setFXFollowDefault() {
        settingsManager.setFXEditingUID(nil)
        settingsManager.setFXDeviceUID(nil)
        settingsManager.setFXDeviceMode(.single)
        let s = normalizedFXSettings(settingsManager.getFXSettings(for: nil))
        fxEditingUID = nil
        fxSettings = s
        fxSettingsForEditing = s
        // Re-apply so the system-layer is correctly assigned to the default-device
        // tap after the routing mode switches back to follow-default.
        applyFXToAllTaps()
    }

    /// Switch to multi-device mode.
    func setFXDeviceMode(_ mode: DeviceSelectionMode) {
        settingsManager.setFXDeviceMode(mode)
        if mode == .single {
            settingsManager.setFXEditingUID(fxDeviceUID)
        }
    }

    /// Update selected device UIDs in multi mode.
    func setFXSelectedDeviceUIDs(_ uids: Set<String>) {
        settingsManager.setFXSelectedDeviceUIDs(uids)
        applyFXToAllTaps()
    }

    /// Returns true when global FX power is enabled.
    func isFXEnabled() -> Bool {
        fxGlobalEnabled
    }

    /// Toggles global FX power for all devices and immediately reapplies taps.
    func setFXEnabled(_ enabled: Bool) {
        fxGlobalEnabled = enabled
        settingsManager.setFXGlobalEnabled(enabled)
        applyFXToAllTaps()
    }

    /// Returns true when this device's FX slot is at the "no real FX" default preset.
    func isFXAtDefaultPreset(forDeviceUID uid: String) -> Bool {
        settingsManager.getFXSettings(for: uid) == FXPreset.defaultPreset.settings
    }

    /// Resets a device's FX slot to the default preset and reapplies active taps.
    func resetFXForDevice(_ uid: String) {
        let reset = FXPreset.defaultPreset.settings
        settingsManager.setFXSettings(reset, for: uid)
        if fxEditingUID == uid {
            fxSettings = reset
            fxSettingsForEditing = reset
        }
        applyFXToAllTaps()
    }

    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    // MARK: - Software Volume (for devices without hardware volume control)

    /// Returns the current software volume (0.0–1.0) for a device.
    /// Reads from the live in-memory dict first; falls back to persisted value so that
    /// devices which haven't fired their reconnect callback yet still show correctly.
    func getSoftwareVolume(for device: AudioDevice) -> Float {
        if let v = deviceVolumeMonitor.softwareVolumes[device.id] { return v }
        // Fallback: seed from persisted value and update in-memory dict
        let persisted = settingsManager.getSoftwareVolume(for: device.uid)
        deviceVolumeMonitor.updateSoftwareVolume(persisted, for: device.id)
        return persisted
    }

    /// Sets the device-level software gain. Writes to SoftwareGainStore (read at render
    /// time by every tap routing to this device) and persists to SettingsManager.
    /// No tap iteration needed — the store is global and polled every render cycle.
    func setSoftwareVolume(for device: AudioDevice, to volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        settingsManager.setSoftwareVolume(for: device.uid, to: clamped)
        deviceVolumeMonitor.updateSoftwareVolume(clamped, for: device.id)
        let isMuted = deviceVolumeMonitor.softwareMuteStates[device.id] ?? false
        SoftwareGainStore.setGain(isMuted ? 0.0 : clamped, for: device.uid)
        softwareVolumesByUID[device.uid] = clamped   // triggers @Observable re-render
        SoftwareVolumeHUD.shared.show(volume: clamped, isMuted: isMuted, deviceName: device.name)
    }

    /// Returns the software mute state for a device.
    func getSoftwareMute(for device: AudioDevice) -> Bool {
        deviceVolumeMonitor.softwareMuteStates[device.id] ?? false
    }

    /// Toggles the software mute. Writes to SoftwareGainStore immediately.
    func setSoftwareMute(for device: AudioDevice, to muted: Bool) {
        settingsManager.setSoftwareMute(for: device.uid, to: muted)
        deviceVolumeMonitor.updateSoftwareMute(muted, for: device.id)
        let vol = deviceVolumeMonitor.softwareVolumes[device.id] ?? 1.0
        SoftwareGainStore.setGain(muted ? 0.0 : vol, for: device.uid)
        softwareMutesByUID[device.uid] = muted       // triggers @Observable re-render
        SoftwareVolumeHUD.shared.show(volume: vol, isMuted: muted, deviceName: device.name)
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

        // Switch tap if needed.
        // Explicitly-routed apps (deviceUID != nil) MUST use stereo mixdown taps —
        // stream-specific taps are tied to a device stream and break when the system
        // default changes. Only follow-default apps can safely use stream-specific taps.
        guard let targetUID = appDeviceRouting[app.id] else { return }
        let isExplicit = deviceUID != nil
        let preferredTapSourceUID = isExplicit ? nil : preferredTapSourceDeviceUID(forOutputUIDs: [targetUID])
        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
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
                    self.rebuildTap(
                        for: app,
                        targetUIDs: [targetUID],
                        useStreamSpecificTap: !isExplicit,
                        reason: "setDevice switch failure"
                    )
                }
            }
        } else {
            ensureTapExists(for: app, deviceUID: targetUID, useStreamSpecificTap: !isExplicit)
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
        let useStreamSpecificTap: Bool
        switch mode {
        case .single:
            if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
                useStreamSpecificTap = true
            } else if let deviceUID = appDeviceRouting[app.id] {
                deviceUIDs = [deviceUID]
                // Explicit single-device routes must remain mixdown-based so they do
                // not get pinned to default-device stream taps.
                useStreamSpecificTap = false
            } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
                useStreamSpecificTap = true
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
            useStreamSpecificTap = true
        }

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    let preferredTapSourceUID = useStreamSpecificTap
                        ? preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs)
                        : nil
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
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
                    rebuildTap(
                        for: app,
                        targetUIDs: deviceUIDs,
                        useStreamSpecificTap: useStreamSpecificTap,
                        reason: "updateTapForCurrentMode switch failure"
                    )
                }
            }
        } else {
            // No tap exists - create one
            if let single = deviceUIDs.first, deviceUIDs.count == 1 {
                ensureTapExists(for: app, deviceUID: single, useStreamSpecificTap: useStreamSpecificTap)
            } else {
                ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs, useStreamSpecificTap: useStreamSpecificTap)
            }
        }
    }

    /// Creates a tap with the specified device UIDs
    private func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String], useStreamSpecificTap: Bool = true) {
        guard !deviceUIDs.isEmpty else { return }
        guard taps[app.id] == nil else { return }

        let preferredTapSourceUID = useStreamSpecificTap
            ? preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs)
            : nil
        let tap = ProcessTapController(
            app: app,
            targetDeviceUIDs: deviceUIDs,
            deviceMonitor: deviceMonitor,
            preferredTapSourceDeviceUID: preferredTapSourceUID
        )
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
            tap.updateFXSettings(fxSettingsForTap(tap))

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
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
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

            // Always create tap for audio apps (always-on strategy).
            // Explicitly-routed apps use stereo mixdown so they survive default-device changes.
            let isFollowing = followsDefault.contains(app.id)
            ensureTapExists(for: app, deviceUID: deviceUID, useStreamSpecificTap: isFollowing)

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

    /// Creates a tap for the given app if one doesn't already exist.
    /// - Parameter useStreamSpecificTap: When `true`, uses a device-stream-specific tap
    ///   for better multichannel preservation (only safe for apps following the default
    ///   device, because stream-specific taps break when the default changes).
    ///   When `false`, forces a stereo mixdown tap that works regardless of which
    ///   device is the system default — required for explicitly-routed apps.
    private func ensureTapExists(for app: AudioApp, deviceUID: String, useStreamSpecificTap: Bool = true) {
        guard taps[app.id] == nil else { return }

        let preferredTapSourceUID = useStreamSpecificTap
            ? preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID])
            : nil
        let tap = ProcessTapController(
            app: app,
            targetDeviceUID: deviceUID,
            deviceMonitor: deviceMonitor,
            preferredTapSourceDeviceUID: preferredTapSourceUID
        )
        tap.volume = volumeState.getVolume(for: app.id)

        // Set initial device volume/mute for VU meter accuracy
        if let device = deviceMonitor.device(for: deviceUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
            // Software gain is read from SoftwareGainStore at render time — no tap-level init needed
        }

        do {
            try tap.activate()
            taps[app.id] = tap

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)
            tap.updateFXSettings(fxSettingsForTap(tap))

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
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
            excluding: excluding
        ) else { return nil }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if target.uid != currentDefault {
            if deviceVolumeMonitor.setDefaultDevice(target.id) {
                outputEchoTracker.increment(target.uid)
                logger.info("System default → \(target.name)")
            }
        }

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
            excluding: excluding
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

        var tapsToSwitch: [(app: AudioApp, tap: ProcessTapController)] = []
        for app in apps {
            guard followsDefault.contains(app.id), let tap = taps[app.id] else { continue }
            tapsToSwitch.append((app, tap))
        }
        guard !tapsToSwitch.isEmpty else { return }

        Task {
            for (app, tap) in tapsToSwitch {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: targetUID)
                    tap.volume = self.volumeState.getVolume(for: app.id)
                    tap.isMuted = self.volumeState.getMute(for: app.id)
                    if let device = self.deviceMonitor.device(for: targetUID) {
                        tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                } catch {
                    self.logger.error("Failed to switch \(app.name) to \(targetUID): \(error.localizedDescription)")
                    self.rebuildTap(
                        for: app,
                        targetUIDs: [targetUID],
                        useStreamSpecificTap: true,
                        reason: "routeFollowsDefaultApps switch failure"
                    )
                }
            }
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
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
            excluding: deviceUID
        )

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
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [fallbackUID])
                        try await tap.switchDevice(to: fallbackUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                        self.rebuildTap(
                            for: tap.app,
                            targetUIDs: [fallbackUID],
                            useStreamSpecificTap: true,
                            reason: "handleDeviceDisconnected single fallback"
                        )
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs)
                        try await tap.updateDevices(to: remainingUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                        self.rebuildTap(
                            for: tap.app,
                            targetUIDs: remainingUIDs,
                            useStreamSpecificTap: true,
                            reason: "handleDeviceDisconnected multi fallback"
                        )
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

        // Restore saved software volume/mute for this device.
        // Covers SW-only devices AND devices with HW control that had a software override saved.
        if let device = deviceMonitor.device(for: deviceUID) {
            let vol = settingsManager.getSoftwareVolume(for: deviceUID)
            let muted = settingsManager.getSoftwareMute(for: deviceUID)
            let hasExplicitVolume = vol != 1.0 || muted
            if !device.id.hasOutputVolumeControl() || hasExplicitVolume {
                deviceVolumeMonitor.updateSoftwareVolume(vol, for: device.id)
                deviceVolumeMonitor.updateSoftwareMute(muted, for: device.id)
                SoftwareGainStore.setGain(muted ? 0.0 : vol, for: deviceUID)
            }
        }

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
                        // Explicitly-pinned apps must always use mixdown taps so they
                        // don't become tied to whichever device is currently default.
                        try await tap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: nil)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        if let device = self.deviceMonitor.device(for: deviceUID) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                        self.rebuildTap(
                            for: tap.app,
                            targetUIDs: [deviceUID],
                            useStreamSpecificTap: false,
                            reason: "handleDeviceConnected explicit restore"
                        )
                    }
                }
            }
        }

        // Second pass: restore multi-device apps that had this device in their selection
        var multiModeTapsToUpdate: [ProcessTapController] = []
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

        // Enforce priority-based system default
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices
        ) else { return }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID

        if target.uid != currentDefault {
            // Highest-priority device isn't the current default — switch immediately
            reEvaluateOutputDefault()
        } else {
            // Highest-priority device IS the current default, but macOS may auto-switch
            // to the newly connected device shortly. Enter PENDING_AUTOSWITCH to catch it.
            if case .pendingAutoSwitch(_, let oldTask) = outputPriorityState {
                oldTask.cancel()
                outputPriorityState = .stable
                reEvaluateOutputDefault()
            }

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

            outputPriorityState = .pendingAutoSwitch(
                connectedDeviceUID: deviceUID,
                timeoutTask: timeoutTask
            )
            logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")
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
        // State machine: if we're waiting for macOS to auto-switch after a device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = outputPriorityState {
            if newDefaultUID == pendingUID {
                // Case 1: macOS auto-switched to the newly connected device — override to priority.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times
                // (common with Bluetooth devices during firmware handshake).
                timeoutTask.cancel()
                reEvaluateOutputDefault()
                let transport = deviceMonitor.device(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.outputPriorityState = .stable
                    self.logger.debug("Auto-switch grace period expired after override")
                }
                outputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }
            // Case 2: Our own echo from the override (e.g. speakers becoming default).
            // Consume it without disrupting the state machine — macOS may still auto-switch again.
            if outputEchoTracker.consume(newDefaultUID) {
                return
            }
            // Case 3: Genuine user intent (different device, not our echo) — respect it.
            timeoutTask.cancel()
            outputPriorityState = .stable
        }

        // Keep the SW-device flag current so the CGEventTap can read it without actor isolation
        volumeKeyInterceptor?.updateSoftwareDeviceFlag()

        // Re-apply FX to all taps — system FX layer follows the default device,
        // so switching default must move that layer to the new default tap.
        applyFXToAllTaps()

        // Suppress echo from our own priority-based override (when not in pendingAutoSwitch)
        if outputEchoTracker.consume(newDefaultUID) {
            return
        }

        // If any echo counter is pending, another override is in flight — skip interim routing
        if outputEchoTracker.hasPending {
            logger.debug("Skipping followsDefault routing — echo pending")
            return
        }

        // Check if the new default device is alive. If it's dead, override to priority fallback.
        // If it's alive, this is a genuine user change — respect it even if a higher-priority device exists.
        let newDeviceIsAlive = deviceMonitor.device(for: newDefaultUID)?.id.isDeviceAlive() ?? false

        if !newDeviceIsAlive {
            // Dead device became default (race with disconnect) — override to priority fallback
            reEvaluateOutputDefault()
        } else {
            // Genuine change to a live device — route followsDefault apps
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

        // Safety net: if any explicitly-routed single-device app was moved by a default-device
        // transition, force it back to its selected device.
        enforceExplicitSingleDeviceRouting()
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

    /// Reassert explicit single-device routing after default-device transitions.
    /// This prevents explicitly-routed apps from drifting to the new default.
    private func enforceExplicitSingleDeviceRouting() {
        var repairs: [(app: AudioApp, tap: ProcessTapController, targetUID: String)] = []

        for app in apps {
            guard !followsDefault.contains(app.id) else { continue }
            guard settingsManager.getDeviceSelectionMode(for: app.persistenceIdentifier) == .single else { continue }
            guard let targetUID = appDeviceRouting[app.id], let tap = taps[app.id] else { continue }
            guard deviceMonitor.device(for: targetUID) != nil else { continue }
            guard tap.currentDeviceUID != targetUID else { continue }
            repairs.append((app, tap, targetUID))
        }

        guard !repairs.isEmpty else { return }

        Task {
            for (app, tap, targetUID) in repairs {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: nil)
                    tap.volume = self.volumeState.getVolume(for: app.id)
                    tap.isMuted = self.volumeState.getMute(for: app.id)
                    if let device = self.deviceMonitor.device(for: targetUID) {
                        tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    self.logger.debug("Repaired explicit routing for \(app.name) -> \(targetUID)")
                } catch {
                    self.logger.error("Failed to repair explicit routing for \(app.name): \(error.localizedDescription)")
                    self.rebuildTap(
                        for: app,
                        targetUIDs: [targetUID],
                        useStreamSpecificTap: false,
                        reason: "enforceExplicitSingleDeviceRouting repair"
                    )
                }
            }
        }
    }

    /// Last-resort recovery when a tap device switch/update fails.
    /// Recreates the tap from scratch with the requested routing so UI state and
    /// actual audio output do not diverge.
    private func rebuildTap(
        for app: AudioApp,
        targetUIDs: [String],
        useStreamSpecificTap: Bool,
        reason: String
    ) {
        guard !targetUIDs.isEmpty else { return }

        if let oldTap = taps.removeValue(forKey: app.id) {
            oldTap.invalidate()
        }

        if let single = targetUIDs.first, targetUIDs.count == 1 {
            ensureTapExists(for: app, deviceUID: single, useStreamSpecificTap: useStreamSpecificTap)
            appDeviceRouting[app.id] = single
        } else {
            ensureTapWithDevices(for: app, deviceUIDs: targetUIDs, useStreamSpecificTap: useStreamSpecificTap)
            appDeviceRouting[app.id] = targetUIDs[0]
        }

        if taps[app.id] != nil {
            logger.info("Rebuilt tap for \(app.name) (\(reason, privacy: .public))")
        } else {
            logger.error("Failed to rebuild tap for \(app.name) (\(reason, privacy: .public))")
        }
    }

    /// Returns the device UID to use for stream-specific tap capture.
    /// Only use stream-specific taping when the selected outputs include the current system default;
    /// otherwise fall back to stereo mixdown to avoid tapping the wrong device stream.
    private func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String]) -> String? {
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
                            self.recreateTap(for: pid)
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
    private func recreateTap(for pid: pid_t) {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        let deviceUIDs = oldTap.currentDeviceUIDs
        oldTap.invalidate()

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
                // Case 1: macOS auto-switched to the newly connected device — override to priority.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times.
                timeoutTask.cancel()
                let resolvedUID = reEvaluateInputDefault()
                if let resolvedUID {
                    settingsManager.setLockedInputDeviceUID(resolvedUID)
                }
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

        // resolve() handles dead-device fallback automatically
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices
        ) else { return }

        if target.uid != newDefaultInputUID {
            // Current default doesn't match priority — override
            reEvaluateInputDefault()
            settingsManager.setLockedInputDeviceUID(target.uid)
        } else {
            // Genuine change that matches priority — update the lock
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
        if deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id) {
            inputEchoTracker.increment(lockedDevice.uid)
        }
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
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when an input device connects — enforces priority via state machine.
    private func handleInputDeviceConnected(_ deviceUID: String, name deviceName: String) {
        guard settingsManager.appSettings.lockInputDevice else { return }

        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices
        ) else { return }

        let currentDefault = deviceVolumeMonitor.defaultInputDeviceUID

        if target.uid != currentDefault {
            reEvaluateInputDefault()
        } else {
            // macOS may auto-switch to the new device. Enter PENDING_AUTOSWITCH.
            if case .pendingAutoSwitch(_, let oldTask) = inputPriorityState {
                oldTask.cancel()
                inputPriorityState = .stable
                reEvaluateInputDefault()
            }

            let transport = deviceMonitor.inputDevice(for: deviceUID)?.id.readTransportType()
            let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                ? btAutoSwitchGracePeriod
                : autoSwitchGracePeriod

            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled else { return }
                self.inputPriorityState = .stable
            }

            inputPriorityState = .pendingAutoSwitch(
                connectedDeviceUID: deviceUID,
                timeoutTask: timeoutTask
            )
        }
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
            excluding: deviceUID
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
                setLockedInputDevice(fallbackDevice)
            }
        } else {
            logger.info("Locked input device disconnected, falling back to built-in mic")
            lockToBuiltInMicrophone()
        }
    }
}
