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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioDeviceMonitor")

    private nonisolated(unsafe) var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var knownDeviceUIDs: Set<String> = []
    private var knownInputDeviceUIDs: Set<String> = []

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

            // Update input devices
            inputDevices = inputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownInputDeviceUIDs = Set(inputDeviceList.map(\.uid))
            inputDevicesByUID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0) })
            inputDevicesByID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.id, $0) })

        } catch {
            logger.error("Failed to refresh device list: \(error.localizedDescription)")
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
        for uid in connectedOutputUIDs {
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
        for uid in connectedInputUIDs {
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
