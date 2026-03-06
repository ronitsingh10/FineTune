// FineTune/Audio/AudioEngine.swift
import AudioToolbox
import Darwin
import Foundation
import os

@Observable
@MainActor
final class AudioEngine {
    let processMonitor = AudioProcessMonitor()
    let deviceMonitor = AudioDeviceMonitor()
    let deviceVolumeMonitor: DeviceVolumeMonitor
    let volumeState: VolumeState
    let settingsManager: SettingsManager

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    private var taps: [pid_t: ProcessTapController] = [:]
    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var pendingStaleCleanupTask: Task<Void, Never>?
    private var tapHealthMonitorTask: Task<Void, Never>?
    private var tapHealthMissesByPID: [pid_t: Int] = [:]
    private var tapRecoveryCooldownUntilByPID: [pid_t: Date] = [:]
    @ObservationIgnored
    private var eqSupportByOutputDevice: [AudioDeviceID: Bool] = [:]
    @ObservationIgnored
    private var eqUnavailableReasonByOutputDevice: [AudioDeviceID: String] = [:]
    private struct SampleRateSnapshot {
        var currentRate: Double
        var availableRates: [Double]
        var canSetRate: Bool
        var fetchedAt: Date
    }
    @ObservationIgnored
    private var sampleRateSnapshotsByDeviceID: [AudioDeviceID: SampleRateSnapshot] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")

    // MARK: - Input Device State

    private let staleCleanupDebounceNs: UInt64 = 350_000_000
    private let staleTapPurgeDelayMs: UInt64 = 30_000
    private let sampleRateCacheTTL: TimeInterval = 0.8

    /// UIDs of priority-based default overrides pending echo suppression (handles rapid disconnects)
    private var pendingPriorityOverrideUIDs: Set<String> = []

    /// Tracks the last known default output device UID for disconnect detection
    private var lastKnownDefaultDeviceUID: String?

    /// Tracks the last known default input device UID for disconnect detection
    private var lastKnownDefaultInputDeviceUID: String?

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    /// Whether a device supports software volume control (CoreAudio or DDC).
    /// Devices without volume control still appear in the list but without slider/mute UI.
    func hasVolumeControl(for deviceID: AudioDeviceID) -> Bool {
        #if !APP_STORE
        // Before DDC probe completes, assume all devices have volume control
        // to avoid premature hiding of controls on monitors that may be DDC-backed
        if !ddcController.probeCompleted { return true }
        return deviceID.hasOutputVolumeControl() || ddcController.isDDCBacked(deviceID)
        #else
        return deviceID.hasOutputVolumeControl()
        #endif
    }

    func availableSampleRates(for deviceID: AudioDeviceID) -> [Double] {
        sampleRateSnapshot(for: deviceID).availableRates
    }

    func currentSampleRate(for deviceID: AudioDeviceID) -> Double {
        sampleRateSnapshot(for: deviceID).currentRate
    }

    func canSetSampleRate(for deviceID: AudioDeviceID) -> Bool {
        sampleRateSnapshot(for: deviceID).canSetRate
    }

    func canDisconnectBluetooth(for device: AudioDevice) -> Bool {
        let transport = device.id.readTransportType()
        return transport == .bluetooth || transport == .bluetoothLE
    }

    func disconnectBluetooth(device: AudioDevice) {
        guard canDisconnectBluetooth(for: device) else { return }

        let disconnected = BluetoothDeviceController.shared.disconnectDevice(matchingAudioDeviceName: device.name)
        if disconnected {
            logger.info("Requested Bluetooth disconnect for \(device.uid, privacy: .public)")
        } else {
            logger.warning("No connected Bluetooth match found for \(device.uid, privacy: .public)")
        }
    }

    private func sampleRateSnapshot(for deviceID: AudioDeviceID) -> SampleRateSnapshot {
        let now = Date()
        if let cached = sampleRateSnapshotsByDeviceID[deviceID],
           now.timeIntervalSince(cached.fetchedAt) < sampleRateCacheTTL {
            return cached
        }

        let snapshot = SampleRateSnapshot(
            currentRate: (try? deviceID.readNominalSampleRate()) ?? 48000,
            availableRates: (try? deviceID.readAvailableNominalSampleRates()) ?? [],
            canSetRate: deviceID.canSetNominalSampleRate(),
            fetchedAt: now
        )
        sampleRateSnapshotsByDeviceID[deviceID] = snapshot
        return snapshot
    }

    private func updateSampleRateSnapshot(for deviceID: AudioDeviceID, currentRate: Double) {
        let existing = sampleRateSnapshot(for: deviceID)
        sampleRateSnapshotsByDeviceID[deviceID] = SampleRateSnapshot(
            currentRate: currentRate,
            availableRates: existing.availableRates,
            canSetRate: existing.canSetRate,
            fetchedAt: Date()
        )
    }

    private func pruneSampleRateCache() {
        let validDeviceIDs = Set(outputDevices.map(\.id)).union(inputDevices.map(\.id))
        sampleRateSnapshotsByDeviceID = sampleRateSnapshotsByDeviceID.filter { validDeviceIDs.contains($0.key) }
    }

    /// Device EQ currently supports stereo tap formats only.
    func isDeviceEQSupported(for deviceID: AudioDeviceID) -> Bool {
        if let cached = eqSupportByOutputDevice[deviceID] {
            return cached
        }
        let channels = deviceID.outputChannelCount()
        let supported = channels == 2
        eqSupportByOutputDevice[deviceID] = supported
        if !supported {
            let detail = "\(channels) channels"
            eqUnavailableReasonByOutputDevice[deviceID] = "EQ is only available for stereo output (device reports \(detail))"
        } else {
            eqUnavailableReasonByOutputDevice.removeValue(forKey: deviceID)
        }
        return supported
    }

    func eqUnavailableReason(for deviceID: AudioDeviceID) -> String? {
        if eqSupportByOutputDevice[deviceID] == nil {
            _ = isDeviceEQSupported(for: deviceID)
        }
        return eqUnavailableReasonByOutputDevice[deviceID]
    }

    private func refreshOutputDeviceEQCapabilities() {
        var support: [AudioDeviceID: Bool] = [:]
        var reasons: [AudioDeviceID: String] = [:]

        for device in deviceMonitor.outputDevices {
            let channels = device.id.outputChannelCount()
            let isSupported = channels == 2
            support[device.id] = isSupported
            if !isSupported {
                let detail = "\(channels) channels"
                reasons[device.id] = "EQ is only available for stereo output (device reports \(detail))"
            }
        }

        eqSupportByOutputDevice = support
        eqUnavailableReasonByOutputDevice = reasons
    }

    func setSampleRate(for device: AudioDevice, to rate: Double) {
        let availableRates = availableSampleRates(for: device.id)
        let supported = availableRates.isEmpty || availableRates.contains { abs($0 - rate) < 1 }
        guard supported else {
            logger.warning("Sample rate \(rate, format: .fixed(precision: 0)) unsupported for \(device.uid, privacy: .public)")
            return
        }

        do {
            try device.id.setNominalSampleRate(rate)
            settingsManager.setPreferredSampleRate(for: device.uid, to: rate)
            updateSampleRateSnapshot(for: device.id, currentRate: rate)
            logger.info("Set sample rate \(rate, format: .fixed(precision: 0)) Hz for \(device.uid, privacy: .public)")
        } catch {
            logger.error("Failed to set sample rate for \(device.uid, privacy: .public): \(error.localizedDescription)")
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

    /// Output devices sorted by priority with hidden devices removed for normal display.
    var visiblePrioritySortedOutputDevices: [AudioDevice] {
        prioritySortedOutputDevices.filter { !settingsManager.isOutputDeviceHidden($0.uid) }
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

    /// Input devices sorted by priority with hidden devices removed for normal display.
    var visiblePrioritySortedInputDevices: [AudioDevice] {
        prioritySortedInputDevices.filter { !settingsManager.isInputDeviceHidden($0.uid) }
    }

    func isDeviceHidden(uid: String, isInput: Bool) -> Bool {
        isInput ? settingsManager.isInputDeviceHidden(uid) : settingsManager.isOutputDeviceHidden(uid)
    }

    func setDeviceHidden(uid: String, isInput: Bool, hidden: Bool) {
        if isInput {
            settingsManager.setInputDeviceHidden(uid, hidden: hidden)
            enforceStrictInputPriorityDefault(trigger: "hidden-input-change")
        } else {
            settingsManager.setOutputDeviceHidden(uid, hidden: hidden)
            enforceStrictOutputPriorityDefault(trigger: "hidden-output-change")
        }
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

    private func applyPreferredSampleRatesToConnectedDevices() {
        for device in outputDevices {
            applyPreferredSampleRateIfNeeded(for: device.uid)
        }
        for device in inputDevices {
            applyPreferredSampleRateIfNeeded(for: device.uid)
        }
    }

    private func applyPreferredSampleRateIfNeeded(for deviceUID: String) {
        guard let preferredRate = settingsManager.getPreferredSampleRate(for: deviceUID) else { return }
        guard let device = deviceMonitor.device(for: deviceUID) ?? deviceMonitor.inputDevice(for: deviceUID) else { return }

        let currentRate = currentSampleRate(for: device.id)
        guard abs(currentRate - preferredRate) >= 1 else { return }
        guard canSetSampleRate(for: device.id) else { return }

        setSampleRate(for: device, to: preferredRate)
    }

    private func highestPriorityConnectedOutputDevice(excluding excludedUID: String? = nil) -> AudioDevice? {
        visiblePrioritySortedOutputDevices.first { device in
            if let excludedUID {
                return device.uid != excludedUID
            }
            return true
        }
    }

    private func highestPriorityConnectedInputDevice(excluding excludedUID: String? = nil) -> AudioDevice? {
        visiblePrioritySortedInputDevices.first { device in
            if let excludedUID {
                return device.uid != excludedUID
            }
            return true
        }
    }

    private func enforceStrictOutputPriorityDefault(trigger: String) {
        guard let highestPriority = highestPriorityConnectedOutputDevice() else { return }
        guard deviceVolumeMonitor.defaultDeviceUID != highestPriority.uid else { return }
        pendingPriorityOverrideUIDs.insert(highestPriority.uid)
        deviceVolumeMonitor.setDefaultDevice(highestPriority.id)
        logger.info("System default overridden to strict priority (\(trigger, privacy: .public)): \(highestPriority.name)")
    }

    private func enforceStrictInputPriorityDefault(trigger: String) {
        guard let highestPriority = highestPriorityConnectedInputDevice() else { return }
        guard deviceVolumeMonitor.defaultInputDeviceUID != highestPriority.uid else { return }
        deviceVolumeMonitor.setDefaultInputDevice(highestPriority.id)
        logger.info("Default input overridden to strict priority (\(trigger, privacy: .public)): \(highestPriority.name)")
    }

    func enforceOutputPriorityDefaultPolicy() {
        enforceStrictOutputPriorityDefault(trigger: "manual")
    }

    func enforceInputPriorityDefaultPolicy() {
        enforceStrictInputPriorityDefault(trigger: "manual")
    }

    /// Finds the highest-priority connected device excluding the given UID.
    func findPriorityFallbackDevice(excluding deviceUID: String) -> (uid: String, name: String)? {
        guard let fallback = highestPriorityConnectedOutputDevice(excluding: deviceUID) else {
            return nil
        }
        return (uid: fallback.uid, name: fallback.name)
    }

    /// Finds the highest-priority connected input device excluding the given UID.
    func findPriorityFallbackInputDevice(excluding deviceUID: String) -> (uid: String, name: String)? {
        guard let fallback = highestPriorityConnectedInputDevice(excluding: deviceUID) else {
            return nil
        }
        return (uid: fallback.uid, name: fallback.name)
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

        Task { @MainActor in
            processMonitor.start()
            deviceMonitor.start()

            #if !APP_STORE
            ddc.onProbeCompleted = { [weak self] in
                self?.deviceVolumeMonitor.refreshAfterDDCProbe()
            }
            ddc.start()
            #endif

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
                self?.applyPersistedSettings()
                self?.scheduleStaleCleanupWork()
            }
            processMonitor.hasActiveTapForPID = { [weak self] pid in
                self?.taps[pid] != nil
            }

            deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceDisconnected(deviceUID, name: deviceName)
                self?.pruneSampleRateCache()
                self?.enforceStrictOutputPriorityDefault(trigger: "output-disconnected")
                self?.refreshOutputDeviceEQCapabilities()
            }

            deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceConnected(deviceUID, name: deviceName)
                self?.applyPreferredSampleRateIfNeeded(for: deviceUID)
                self?.pruneSampleRateCache()
                self?.enforceStrictOutputPriorityDefault(trigger: "output-connected")
                self?.refreshOutputDeviceEQCapabilities()
            }

            deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
                self?.handleInputDeviceDisconnected(deviceUID)
                self?.pruneSampleRateCache()
                self?.enforceStrictInputPriorityDefault(trigger: "input-disconnected")
            }

            deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
                self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
                self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
                self?.applyPreferredSampleRateIfNeeded(for: deviceUID)
                self?.pruneSampleRateCache()
                self?.enforceStrictInputPriorityDefault(trigger: "input-connected")
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
            startTapHealthMonitorIfNeeded()
            registerNewDevicesInPriority()
            applyPreferredSampleRatesToConnectedDevices()
            refreshOutputDeviceEQCapabilities()
            pruneSampleRateCache()
            lastKnownDefaultDeviceUID = deviceVolumeMonitor.defaultDeviceUID
            lastKnownDefaultInputDeviceUID = deviceVolumeMonitor.defaultInputDeviceUID
            enforceStrictOutputPriorityDefault(trigger: "startup")
            enforceStrictInputPriorityDefault(trigger: "startup")
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps.filter { !isExcluded($0) }
    }

    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Pinned apps appear first (sorted alphabetically), then unpinned active apps (sorted alphabetically).
    var displayableApps: [DisplayableApp] {
        // Start from currently active CoreAudio apps.
        var appsByIdentifier: [String: AudioApp] = [:]
        for app in processMonitor.activeApps {
            guard !settingsManager.isExcludedApp(app.persistenceIdentifier) else { continue }
            appsByIdentifier[app.persistenceIdentifier] = app
        }

        // Retain recently-active apps that still have a live tap (stale cleanup window),
        // but only while the process is still alive.
        for tap in taps.values {
            let app = tap.app
            guard !settingsManager.isExcludedApp(app.persistenceIdentifier) else { continue }
            guard isProcessCurrentlyAlive(app.id) else { continue }
            if appsByIdentifier[app.persistenceIdentifier] == nil {
                appsByIdentifier[app.persistenceIdentifier] = app
            }
        }

        let activeApps = Array(appsByIdentifier.values)
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = settingsManager.getPinnedAppInfo()
            .filter {
                !activeIdentifiers.contains($0.persistenceIdentifier)
                && !settingsManager.isExcludedApp($0.persistenceIdentifier)
            }

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

    private func isProcessCurrentlyAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
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

    func excludeApp(identifier: String) {
        guard !settingsManager.isExcludedApp(identifier) else { return }
        settingsManager.excludeApp(identifier)
        settingsManager.unpinApp(identifier)

        var removedCount = 0
        let matchingPIDs = taps.compactMap { pid, tap in
            tap.app.persistenceIdentifier == identifier ? pid : nil
        }

        for pid in matchingPIDs {
            if let tap = taps.removeValue(forKey: pid) {
                tap.invalidate()
                removedCount += 1
            }
            appliedPIDs.remove(pid)
            followsDefault.remove(pid)
            appDeviceRouting.removeValue(forKey: pid)
            pendingCleanup[pid]?.cancel()
            pendingCleanup.removeValue(forKey: pid)
            volumeState.removeVolume(for: pid)
        }

        logger.info("Excluded app \(identifier, privacy: .public); removed \(removedCount) active tap(s)")
    }

    func includeApp(identifier: String) {
        guard settingsManager.isExcludedApp(identifier) else { return }
        settingsManager.includeApp(identifier)
        logger.info("Included app \(identifier, privacy: .public)")
        applyPersistedSettings()
    }

    func isExcluded(_ app: AudioApp) -> Bool {
        settingsManager.isExcludedApp(app.persistenceIdentifier)
    }

    private func effectiveEQSettings(for app: AudioApp, deviceUID: String? = nil) -> EQSettings {
        let resolvedDeviceUID = deviceUID
            ?? appDeviceRouting[app.id]
            ?? deviceVolumeMonitor.defaultDeviceUID
        return settingsManager.getEffectiveEQSettings(deviceUID: resolvedDeviceUID)
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
        levels.reserveCapacity(taps.count)
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
        startTapHealthMonitorIfNeeded()

        logger.info("AudioEngine started")
    }

    func stop() {
        pendingStaleCleanupTask?.cancel()
        pendingStaleCleanupTask = nil
        tapHealthMonitorTask?.cancel()
        tapHealthMonitorTask = nil
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

    private func scheduleStaleCleanupWork() {
        pendingStaleCleanupTask?.cancel()
        pendingStaleCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: staleCleanupDebounceNs)
            guard !Task.isCancelled else { return }
            self.cleanupStaleTaps()
        }
    }

    private func startTapHealthMonitorIfNeeded() {
        guard tapHealthMonitorTask == nil else { return }
        tapHealthMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.recoverUnhealthyActiveTaps()
            }
        }
    }

    /// Recreates active taps that silently stop receiving callbacks while the app remains active.
    /// This targets in-playback non-helper dropouts where tap resources can disconnect without PID churn.
    private func recoverUnhealthyActiveTaps() {
        let now = Date()
        let activePIDs = Set(apps.map(\.id))
        tapHealthMissesByPID = tapHealthMissesByPID.filter { activePIDs.contains($0.key) }
        tapRecoveryCooldownUntilByPID = tapRecoveryCooldownUntilByPID.filter { activePIDs.contains($0.key) }

        var recreatedAny = false

        for app in apps {
            guard !isExcluded(app), let tap = taps[app.id] else { continue }

            if shouldRecreateTap(existingTap: tap, for: app) {
                logger.info("Recreating tap for \(app.name) due to process object identity change")
                tap.invalidate()
                taps.removeValue(forKey: app.id)
                appliedPIDs.remove(app.id)
                tapHealthMissesByPID[app.id] = 0
                tapRecoveryCooldownUntilByPID[app.id] = now.addingTimeInterval(20)
                recreatedAny = true
                continue
            }

            // Skip muted apps; no-audio callbacks while muted are not a useful health signal.
            if volumeState.getMute(for: app.id) {
                tapHealthMissesByPID[app.id] = 0
                continue
            }

            guard tap.isHealthCheckEligible(minActiveSeconds: 8.0) else {
                tapHealthMissesByPID[app.id] = 0
                continue
            }

            if let cooldownUntil = tapRecoveryCooldownUntilByPID[app.id], cooldownUntil > now {
                tapHealthMissesByPID[app.id] = 0
                continue
            }

            if tap.hasRecentAudioCallback(within: 2.5) {
                tapHealthMissesByPID[app.id] = 0
                continue
            }

            let misses = (tapHealthMissesByPID[app.id] ?? 0) + 1
            tapHealthMissesByPID[app.id] = misses

            // Require multiple consecutive missed heartbeats before touching HAL.
            if misses >= 3 {
                logger.warning("Recreating tap for \(app.name) after \(misses) missed callback heartbeats")
                tap.invalidate()
                taps.removeValue(forKey: app.id)
                appliedPIDs.remove(app.id)
                tapHealthMissesByPID[app.id] = 0
                tapRecoveryCooldownUntilByPID[app.id] = now.addingTimeInterval(20)
                recreatedAny = true
            }
        }

        // Re-apply persisted settings only if we invalidated at least one tap.
        if recreatedAny {
            applyPersistedSettings()
        }
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        let currentVolume = volumeState.getVolume(for: app.id)
        if abs(currentVolume - volume) <= 0.0005 {
            return
        }
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

    func getDeviceEQSettings(for deviceUID: String) -> EQSettings {
        settingsManager.getDeviceEQSettings(for: deviceUID)
    }

    func setDeviceEQSettings(for deviceUID: String, to settings: EQSettings) {
        settingsManager.setDeviceEQSettings(settings, for: deviceUID)

        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            tap.updateEQSettings(settings)
        }
    }

    func getDeviceHeadphoneEQSettings(for deviceUID: String) -> HeadphoneEQSettings {
        settingsManager.getDeviceHeadphoneEQSettings(for: deviceUID)
    }

    func setDeviceHeadphoneEQSettings(for deviceUID: String, to settings: HeadphoneEQSettings) {
        settingsManager.setDeviceHeadphoneEQSettings(settings, for: deviceUID)

        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            tap.updateHeadphoneEQSettings(settings)
        }
    }

    func importHeadphoneEQProfile(for deviceUID: String, from fileURL: URL) -> Result<HeadphoneEQSettings, Error> {
        do {
            var imported = try AutoEQPEQParser.parseFile(at: fileURL)
            imported.isEnabled = true
            settingsManager.setDeviceHeadphoneEQSettings(imported, for: deviceUID)

            for tap in taps.values {
                guard tap.currentDeviceUID == deviceUID else { continue }
                tap.updateHeadphoneEQSettings(imported)
            }

            return .success(imported)
        } catch {
            return .failure(error)
        }
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
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [targetUID])
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
                    tap.updateEQSettings(self.effectiveEQSettings(for: app, deviceUID: targetUID))
                    tap.updateHeadphoneEQSettings(self.settingsManager.getDeviceHeadphoneEQSettings(for: targetUID))
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
        guard !isExcluded(app) else { return }
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
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs)
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    tap.volume = volumeState.getVolume(for: app.id)
                    tap.isMuted = volumeState.getMute(for: app.id)
                    // Update device volume for VU meter (use primary device)
                    if let primaryUID = deviceUIDs.first,
                       let device = deviceMonitor.device(for: primaryUID) {
                        tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    if let primaryUID = deviceUIDs.first {
                        tap.updateEQSettings(effectiveEQSettings(for: app, deviceUID: primaryUID))
                        tap.updateHeadphoneEQSettings(settingsManager.getDeviceHeadphoneEQSettings(for: primaryUID))
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
        guard !isExcluded(app) else { return }
        guard !deviceUIDs.isEmpty else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs)
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

            // Apply effective EQ (app override if present, otherwise device EQ)
            let eqSettings = effectiveEQSettings(for: app, deviceUID: deviceUIDs.first)
            tap.updateEQSettings(eqSettings)
            if let primaryUID = deviceUIDs.first {
                tap.updateHeadphoneEQSettings(settingsManager.getDeviceHeadphoneEQSettings(for: primaryUID))
            }

            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    func applyPersistedSettings() {
        for app in apps {
            guard !isExcluded(app) else { continue }
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

    /// CoreAudio can rotate process object IDs while PID remains stable.
    /// Existing taps bound to stale object IDs may stop processing until recreated.
    private func shouldRecreateTap(existingTap: ProcessTapController, for app: AudioApp) -> Bool {
        let existingApp = existingTap.app
        let objectIDChanged = existingApp.objectID != app.objectID
        let currentObjectIDs = Set(existingApp.processObjectIDs)
        let latestObjectIDs = Set(app.processObjectIDs)
        let objectSetChanged = currentObjectIDs != latestObjectIDs

        guard objectIDChanged || objectSetChanged else { return false }

        // Helper-backed object sets can reorder and drop stale object IDs frequently.
        // Ignore pure reordering/removal deltas, but recreate when new helper objects appear
        // so the tap can follow the active render object as helpers roll over.
        if existingApp.isHelperBacked || app.isHelperBacked {
            let addedObjectIDs = latestObjectIDs.subtracting(currentObjectIDs)
            if addedObjectIDs.isEmpty {
                return false
            }
        }

        return true
    }

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard !isExcluded(app) else { return }
        guard taps[app.id] == nil else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID])
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
        }

        do {
            try tap.activate()
            taps[app.id] = tap

            // Apply effective EQ (app override if present, otherwise device EQ)
            let eqSettings = effectiveEQSettings(for: app, deviceUID: deviceUID)
            tap.updateEQSettings(eqSettings)
            tap.updateHeadphoneEQSettings(settingsManager.getDeviceHeadphoneEQSettings(for: deviceUID))

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Snapshot before async callbacks can update it
        let wasDefaultOutput = deviceUID == deviceVolumeMonitor.defaultDeviceUID

        // Use priority-based fallback, then system default, then any device
        let fallbackDevice: (uid: String, name: String)?
        if let priorityFallback = findPriorityFallbackDevice(excluding: deviceUID) {
            fallbackDevice = priorityFallback
        } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID,
                  let device = deviceMonitor.device(for: defaultUID) {
            fallbackDevice = (uid: defaultUID, name: device.name)
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
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [fallbackUID])
                        try await tap.switchDevice(to: fallbackUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        tap.updateEQSettings(self.effectiveEQSettings(for: tap.app, deviceUID: fallbackUID))
                        tap.updateHeadphoneEQSettings(self.settingsManager.getDeviceHeadphoneEQSettings(for: fallbackUID))
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs)
                        try await tap.updateDevices(to: remainingUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        tap.updateEQSettings(self.effectiveEQSettings(for: tap.app, deviceUID: remainingUIDs.first))
                        if let primaryUID = remainingUIDs.first {
                            tap.updateHeadphoneEQSettings(self.settingsManager.getDeviceHeadphoneEQSettings(for: primaryUID))
                        }
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) affected")
        }

        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput,
           let fallback = fallbackDevice,
           let fallbackAudioDevice = deviceMonitor.device(for: fallback.uid) {
            pendingPriorityOverrideUIDs.insert(fallback.uid)
            deviceVolumeMonitor.setDefaultDevice(fallbackAudioDevice.id)
            logger.info("System default overridden to priority fallback: \(fallback.name)")
        }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        // Register newly connected device in priority list
        settingsManager.ensureDeviceInPriority(deviceUID)

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
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID])
                        try await tap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        tap.volume = self.volumeState.getVolume(for: tap.app.id)
                        tap.isMuted = self.volumeState.getMute(for: tap.app.id)
                        if let device = self.deviceMonitor.device(for: deviceUID) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                        tap.updateEQSettings(self.effectiveEQSettings(for: tap.app, deviceUID: deviceUID))
                        tap.updateHeadphoneEQSettings(self.settingsManager.getDeviceHeadphoneEQSettings(for: deviceUID))
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
        }
    }

    /// Called when system default output device changes - switches apps that follow default
    private func handleDefaultDeviceChanged(_ newDefaultUID: String) {
        let oldDefaultUID = lastKnownDefaultDeviceUID
        lastKnownDefaultDeviceUID = newDefaultUID

        // Consume one-shot suppression marker set when we initiate a default-device change.
        let wasPriorityOverride = pendingPriorityOverrideUIDs.remove(newDefaultUID) != nil

        if !wasPriorityOverride {
            // If the old default device was disconnected, override to priority fallback.
            // Use isDeviceAlive() to query Core Audio directly (cache may be stale).
            if let oldUID = oldDefaultUID,
               let oldDevice = deviceMonitor.device(for: oldUID),
               !oldDevice.id.isDeviceAlive() {
                if let fallback = findPriorityFallbackDevice(excluding: oldUID),
                   fallback.uid != newDefaultUID,
                   let fallbackDevice = deviceMonitor.device(for: fallback.uid) {
                    pendingPriorityOverrideUIDs.insert(fallback.uid)
                    deviceVolumeMonitor.setDefaultDevice(fallbackDevice.id)
                    logger.info("System default overridden to priority fallback: \(fallback.name)")
                    return
                }
            }
        }

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
                        try await tap.switchDevice(to: newDefaultUID, preferredTapSourceDeviceUID: newDefaultUID)
                        tap.volume = self.volumeState.getVolume(for: app.id)
                        tap.isMuted = self.volumeState.getMute(for: app.id)
                        if let device = self.deviceMonitor.device(for: newDefaultUID) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                        tap.updateEQSettings(self.effectiveEQSettings(for: app, deviceUID: newDefaultUID))
                        tap.updateHeadphoneEQSettings(self.settingsManager.getDeviceHeadphoneEQSettings(for: newDefaultUID))
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
        }
    }

    /// Returns the device UID to use for stream-specific tap capture.
    /// Only use stream-specific taping when the selected outputs include the current system default;
    /// otherwise fall back to stereo mixdown to avoid tapping the wrong device stream.
    private func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String]) -> String? {
        guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else { return nil }
        return outputUIDs.contains(defaultUID) ? defaultUID : nil
    }

    func cleanupStaleTaps() {
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
                try? await Task.sleep(for: .milliseconds(staleTapPurgeDelayMs))
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

    // MARK: - Input Device Handling

    /// Handles changes to the default input device.
    /// If the previous default disappeared, enforce priority fallback.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        let oldDefaultInputUID = lastKnownDefaultInputDeviceUID
        lastKnownDefaultInputDeviceUID = newDefaultInputUID

        // If the old default input device was disconnected, override to priority fallback.
        // This handles the race where default-changed fires before device-list-changed.
        if let oldUID = oldDefaultInputUID,
           let oldDevice = deviceMonitor.inputDevice(for: oldUID),
           !oldDevice.id.isDeviceAlive(),
           let fallback = findPriorityFallbackInputDevice(excluding: oldUID),
           fallback.uid != newDefaultInputUID,
           let fallbackDevice = deviceMonitor.inputDevice(for: fallback.uid) {
            deviceVolumeMonitor.setDefaultInputDevice(fallbackDevice.id)
            logger.info("Default input overridden to priority fallback: \(fallback.name)")
        }
    }

    /// Called when user explicitly selects an input device in FineTune.
    func setDefaultInputDevice(_ device: AudioDevice) {
        logger.info("User selected input device: \(device.name)")
        deviceVolumeMonitor.setDefaultInputDevice(device.id)
    }

    /// Handles input device disconnect — uses priority fallback.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        // Snapshot before async callbacks can update it
        let wasDefaultInput = deviceUID == deviceVolumeMonitor.defaultInputDeviceUID

        let priorityFallback: AudioDevice? = findPriorityFallbackInputDevice(excluding: deviceUID)
            .flatMap { deviceMonitor.inputDevice(for: $0.uid) }

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput,
           let fallbackDevice = priorityFallback {
            deviceVolumeMonitor.setDefaultInputDevice(fallbackDevice.id)
            logger.info("Default input overridden to priority fallback: \(fallbackDevice.name)")
        }
    }
}
