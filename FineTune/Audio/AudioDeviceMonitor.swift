// FineTune/Audio/AudioDeviceMonitor.swift
import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class AudioDeviceMonitor {
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

    private nonisolated(unsafe) var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var knownDeviceUIDs: Set<String> = []
    private var knownInputDeviceUIDs: Set<String> = []
    @ObservationIgnored private var dataSourceListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]

    func start() {
        guard deviceListListenerBlock == nil else { return }

        logger.debug("Starting audio device monitor")

        refresh()

        deviceListListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDeviceListChanged()
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

        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &deviceListAddress, .main, block)
            deviceListListenerBlock = nil
        }
        removeAllDataSourceListeners()
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
                guard !deviceID.isAggregateDevice() else { continue }

                guard let uid = try? deviceID.readDeviceUID(),
                      let name = try? deviceID.readDeviceName() else {
                    continue
                }

                // Output devices - filter virtual devices (avoid clutter from Teams Audio, BlackHole, etc.)
                if deviceID.hasOutputStreams() && !deviceID.isVirtualDevice() {
                    // Try Core Audio icon first (via LRU cache), fall back to SF Symbol
                    let icon = DeviceIconCache.shared.icon(for: uid) {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedIconSymbol(), accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon
                    )
                    outputDeviceList.append(device)
                }

                // Input devices - allow virtual devices but filter zombies
                if deviceID.hasInputStreams() {
                    // Skip zombie virtual devices (registered but not functional, e.g., Teams Audio when Teams not running)
                    if deviceID.isVirtualDevice() && !deviceID.isDeviceAlive() {
                        continue
                    }

                    // Try Core Audio icon first, fall back to smart detection
                    let icon = DeviceIconCache.shared.icon(for: uid) {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedInputIconSymbol(),
                                 accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon
                    )
                    inputDeviceList.append(device)
                }
            }

            // Update output devices
            outputDevices = outputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownDeviceUIDs = Set(outputDeviceList.map(\.uid))
            devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
            devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })
            syncDataSourceListeners(outputDeviceIDs: outputDeviceList.map(\.id))

            // Update input devices
            inputDevices = inputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownInputDeviceUIDs = Set(inputDeviceList.map(\.uid))
            inputDevicesByUID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0) })
            inputDevicesByID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.id, $0) })

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
                    self?.handleDeviceListChanged()
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
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
    }

    private func removeAllDataSourceListeners() {
        for deviceID in dataSourceListeners.keys {
            removeDataSourceListener(for: deviceID)
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

    nonisolated deinit {
        // HAL C functions don't require actor isolation
        if let block = deviceListListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(.system, &addr, .main, block)
        }
    }
}
