// FineTune/Audio/Monitors/AudioDeviceMonitor.swift
import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class AudioDeviceMonitor: AudioDeviceProviding {
    // MARK: - Output Devices

    private(set) var outputDevices: [AudioDevice] = []

    /// O(1) device lookup by UID
    private(set) var devicesByUID: [String: AudioDevice] = [:]

    /// O(1) device lookup by AudioDeviceID
    private(set) var devicesByID: [AudioDeviceID: AudioDevice] = [:]

    /// Called immediately when output device disappears (passes UID and name)
    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?

    /// Called when an output device appears (passes UID and name)
    var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)?

    // MARK: - Input Devices

    private(set) var inputDevices: [AudioDevice] = []

    /// O(1) input device lookup by UID
    private(set) var inputDevicesByUID: [String: AudioDevice] = [:]

    /// O(1) input device lookup by AudioDeviceID
    private(set) var inputDevicesByID: [AudioDeviceID: AudioDevice] = [:]

    /// Called immediately when input device disappears (passes UID and name)
    var onInputDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?

    /// Called when an input device appears (passes UID and name)
    var onInputDeviceConnected: ((_ uid: String, _ name: String) -> Void)?

    /// Returns current output device priority order (highest priority first) for deterministic callback ordering
    var outputPriorityOrder: (() -> [String])?

    /// Returns current input device priority order (highest priority first) for deterministic callback ordering
    var inputPriorityOrder: (() -> [String])?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioDeviceMonitor")

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var knownDeviceUIDs: Set<String> = []
    private var knownInputDeviceUIDs: Set<String> = []

    /// Called when a BT output device crosses the A2DP ↔ SCO/HFP sample-rate threshold (44.1 kHz).
    var onBTDeviceSampleRateChanged: ((_ uid: String, _ newRate: Double) -> Void)?

    /// Listeners for kAudioDevicePropertyDataSource changes on built-in devices (headphone jack detection)
    @ObservationIgnored private var dataSourceListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]

    /// Listeners for kAudioDevicePropertyNominalSampleRate changes on BT output devices
    @ObservationIgnored private var sampleRateListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var lastKnownSampleRates: [AudioDeviceID: Double] = [:]
    @ObservationIgnored private var sampleRateDebounce: [AudioDeviceID: Task<Void, Never>] = [:]

    /// Debounces rapid HAL device-list notifications (e.g. Bluetooth connect fires 2-3 in ~20ms).
    /// Querying device properties during the burst produces HALC_ShellObject errors because
    /// HAL proxy objects are mid-transition. 50ms lets the HAL stabilize before we enumerate.
    private var deviceListDebounceTask: Task<Void, Never>?

    func start() {
        guard deviceListListenerBlock == nil else { return }

        logger.debug("Starting audio device monitor")

        refresh()

        deviceListListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceListRefresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            .system,
            &deviceListAddress,
            .main,
            deviceListListenerBlock!
        )

        if status != noErr {
            logger.error("Failed to add device list listener: \(status)")
        }
    }

    func stop() {
        logger.debug("Stopping audio device monitor")

        deviceListDebounceTask?.cancel()
        deviceListDebounceTask = nil

        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &deviceListAddress, .main, block)
            deviceListListenerBlock = nil
        }
        removeAllDataSourceListeners()
        removeAllSampleRateListeners()
    }

    /// O(1) lookup by device UID (output devices)
    func device(for uid: String) -> AudioDevice? {
        devicesByUID[uid]
    }

    /// O(1) lookup by AudioDeviceID (output devices)
    func device(for id: AudioDeviceID) -> AudioDevice? {
        devicesByID[id]
    }

    /// O(1) lookup by device UID (input devices)
    func inputDevice(for uid: String) -> AudioDevice? {
        inputDevicesByUID[uid]
    }

    /// O(1) lookup by AudioDeviceID (input devices)
    func inputDevice(for id: AudioDeviceID) -> AudioDevice? {
        inputDevicesByID[id]
    }

    private func refresh() {
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var outputDeviceList: [AudioDevice] = []
            var inputDeviceList: [AudioDevice] = []

            for deviceID in deviceIDs {
                guard let uid = try? deviceID.readDeviceUID(),
                      let name = try? deviceID.readDeviceName() else {
                    continue
                }

                // FineTune's own internal aggregates (used for process taps) are
                // `kAudioAggregateDeviceIsPrivateKey: true`, but still visible to the
                // creating process. Skip them by name prefix so they don't appear in
                // our own picker. User-created aggregates (Audio MIDI Setup Multi-Output,
                // etc.) pass through.
                if deviceID.isAggregateDevice() && name.hasPrefix("FineTune-") { continue }

                // Respect the driver's own opt-out. `kAudioDevicePropertyIsHidden` is
                // how drivers signal "maintenance/utility device, don't show in
                // pickers" — mirrors what Apple's System Settings does.
                if deviceID.isHidden() { continue }

                // Output devices. Virtual outputs (BlackHole, Loopback, Teams Audio)
                // are NOT filtered out here — users who don't want them in their
                // picker can hide them per-device via the reorder-mode eye toggle.
                if deviceID.hasOutputStreams() {
                    // Try Core Audio icon first (via LRU cache), fall back to SF Symbol
                    let icon = DeviceIconCache.shared.icon(for: uid) {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedIconSymbol(), accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon,
                        supportsAutoEQ: deviceID.supportsAutoEQ()
                    )
                    outputDeviceList.append(device)
                }

                // Input devices. Zombie virtuals (registered but not alive — e.g.
                // Teams Audio when Teams isn't running) are no longer filtered
                // here; the hide toggle provides per-device suppression.
                if deviceID.hasInputStreams() {
                    // Try Core Audio icon first, fall back to smart detection
                    let icon = DeviceIconCache.shared.icon(for: uid) {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedInputIconSymbol(),
                                 accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon,
                        supportsAutoEQ: false
                    )
                    inputDeviceList.append(device)
                }
            }

            // Update output devices
            outputDevices = outputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownDeviceUIDs = Set(outputDeviceList.map(\.uid))
            devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
            devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

            // Update input devices
            inputDevices = inputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownInputDeviceUIDs = Set(inputDeviceList.map(\.uid))
            inputDevicesByUID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0) })
            inputDevicesByID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.id, $0) })

            syncDataSourceListeners(outputDeviceIDs: outputDeviceList.map(\.id))
            let btOutputIDs = Set(outputDeviceList.filter { $0.id.isBluetoothDevice() }.map(\.id))
            syncSampleRateListeners(btOutputDeviceIDs: btOutputIDs)

        } catch {
            logger.error("Failed to refresh device list: \(error.localizedDescription)")
        }
    }

    /// Installs/removes kAudioDevicePropertyDataSource listeners on built-in output devices
    /// so headphone jack plug/unplug triggers a refresh.
    private func syncDataSourceListeners(outputDeviceIDs: [AudioDeviceID]) {
        let builtInIDs = Set(outputDeviceIDs.filter { $0.readTransportType() == .builtIn })
        let currentIDs = Set(dataSourceListeners.keys)

        // Remove listeners for devices no longer present
        for deviceID in currentIDs.subtracting(builtInIDs) {
            removeDataSourceListener(for: deviceID)
        }

        // Add listeners for new built-in devices
        for deviceID in builtInIDs.subtracting(currentIDs) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDeviceListRefresh()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
            if status == noErr {
                dataSourceListeners[deviceID] = block
            } else {
                logger.warning("Failed to add data source listener for device \(deviceID): \(status)")
            }
        }
    }

    private func removeDataSourceListener(for deviceID: AudioDeviceID) {
        guard let block = dataSourceListeners.removeValue(forKey: deviceID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        // Tolerate kAudioHardwareBadObjectError (-66680): device was already destroyed
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove data source listener for device \(deviceID): \(status)")
        }
    }

    private func removeAllDataSourceListeners() {
        for deviceID in Array(dataSourceListeners.keys) {
            removeDataSourceListener(for: deviceID)
        }
    }

    /// Installs/removes kAudioDevicePropertyNominalSampleRate listeners on BT output devices
    /// so A2DP ↔ SCO/HFP mode switches trigger tap recreation.
    private func syncSampleRateListeners(btOutputDeviceIDs: Set<AudioDeviceID>) {
        let currentIDs = Set(sampleRateListeners.keys)

        for deviceID in currentIDs.subtracting(btOutputDeviceIDs) {
            removeSampleRateListener(for: deviceID)
        }

        for deviceID in btOutputDeviceIDs.subtracting(currentIDs) {
            guard let uid = devicesByID[deviceID]?.uid else { continue }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleSampleRateCheck(forDeviceID: deviceID, uid: uid)
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
            if status == noErr {
                sampleRateListeners[deviceID] = block
                lastKnownSampleRates[deviceID] = (try? deviceID.readNominalSampleRate()) ?? 0
            } else {
                logger.warning("Failed to add sample rate listener for BT device \(deviceID): \(status)")
            }
        }
    }

    private func scheduleSampleRateCheck(forDeviceID deviceID: AudioDeviceID, uid: String) {
        sampleRateDebounce[deviceID]?.cancel()
        sampleRateDebounce[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.checkSampleRateThreshold(forDeviceID: deviceID, uid: uid)
        }
    }

    private func checkSampleRateThreshold(forDeviceID deviceID: AudioDeviceID, uid: String) {
        let newRate = (try? deviceID.readNominalSampleRate()) ?? 0
        let oldRate = lastKnownSampleRates[deviceID] ?? 0
        lastKnownSampleRates[deviceID] = newRate

        // Skip transient HAL failures (newRate == 0).
        guard newRate > 0 else { return }

        if oldRate == 0 {
            // No valid baseline yet — only act if device settled at A2DP (≥ 44.1 kHz).
            // The tap was created without ghost clock (rate was 0, indistinguishable from SCO);
            // rebuilding it now lets builtInGhostClockUID pick the correct strategy.
            guard newRate >= 44_100 else { return }
        } else {
            let wasCallMode = oldRate < 44_100
            let isCallMode = newRate < 44_100
            guard wasCallMode != isCallMode else { return }
        }

        logger.info("[RATE] BT device \(uid, privacy: .public) \(oldRate, format: .fixed(precision: 0)) → \(newRate, format: .fixed(precision: 0)) Hz (call mode: \(newRate < 44_100))")
        onBTDeviceSampleRateChanged?(uid, newRate)
    }

    private func removeSampleRateListener(for deviceID: AudioDeviceID) {
        sampleRateDebounce[deviceID]?.cancel()
        sampleRateDebounce.removeValue(forKey: deviceID)
        lastKnownSampleRates.removeValue(forKey: deviceID)

        guard let block = sampleRateListeners.removeValue(forKey: deviceID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove sample rate listener for BT device \(deviceID): \(status)")
        }
    }

    private func removeAllSampleRateListeners() {
        for deviceID in Array(sampleRateListeners.keys) {
            removeSampleRateListener(for: deviceID)
        }
    }

    /// Sorts UIDs by priority order: UIDs in the priority list come first (in priority order),
    /// followed by any remaining UIDs sorted alphabetically for determinism.
    private func sortByPriority(uids: Set<String>, priorityOrder: [String]) -> [String] {
        guard uids.count > 1 else { return Array(uids) }
        var sorted: [String] = []
        for uid in priorityOrder where uids.contains(uid) {
            sorted.append(uid)
        }
        let remaining = uids.subtracting(sorted).sorted()
        sorted.append(contentsOf: remaining)
        return sorted
    }

    /// Coalesces rapid HAL notifications into a single refresh after 50ms of quiet.
    /// Without this, querying device properties mid-burst produces HALC_ShellObject errors
    /// because HAL proxy objects haven't stabilized yet.
    private func scheduleDeviceListRefresh() {
        deviceListDebounceTask?.cancel()
        deviceListDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.handleDeviceListChanged()
        }
    }

    private func handleDeviceListChanged() {
        let previousOutputUIDs = knownDeviceUIDs
        let previousInputUIDs = knownInputDeviceUIDs

        // Capture names before refresh removes devices from list
        var outputDeviceNames: [String: String] = [:]
        for device in outputDevices {
            outputDeviceNames[device.uid] = device.name
        }
        var inputDeviceNames: [String: String] = [:]
        for device in inputDevices {
            inputDeviceNames[device.uid] = device.name
        }

        refresh()

        // Handle output device changes
        let currentOutputUIDs = knownDeviceUIDs
        let disconnectedOutputUIDs = previousOutputUIDs.subtracting(currentOutputUIDs)
        for uid in disconnectedOutputUIDs {
            let name = outputDeviceNames[uid] ?? uid
            logger.info("Output device disconnected: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
        }
        let connectedOutputUIDs = currentOutputUIDs.subtracting(previousOutputUIDs)
        let sortedConnectedOutput = sortByPriority(uids: connectedOutputUIDs, priorityOrder: outputPriorityOrder?() ?? [])
        for uid in sortedConnectedOutput {
            if let device = devicesByUID[uid] {
                logger.info("Output device connected: \(device.name) (\(uid))")
                onDeviceConnected?(uid, device.name)
            }
        }

        // Handle input device changes
        let currentInputUIDs = knownInputDeviceUIDs
        let disconnectedInputUIDs = previousInputUIDs.subtracting(currentInputUIDs)
        for uid in disconnectedInputUIDs {
            let name = inputDeviceNames[uid] ?? uid
            logger.info("Input device disconnected: \(name) (\(uid))")
            onInputDeviceDisconnected?(uid, name)
        }
        let connectedInputUIDs = currentInputUIDs.subtracting(previousInputUIDs)
        let sortedConnectedInput = sortByPriority(uids: connectedInputUIDs, priorityOrder: inputPriorityOrder?() ?? [])
        for uid in sortedConnectedInput {
            if let device = inputDevicesByUID[uid] {
                logger.info("Input device connected: \(device.name) (\(uid))")
                onInputDeviceConnected?(uid, device.name)
            }
        }
    }

}
