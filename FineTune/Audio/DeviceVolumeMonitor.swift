// FineTune/Audio/DeviceVolumeMonitor.swift
import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class DeviceVolumeMonitor {
    /// Volumes for all tracked output devices (keyed by AudioDeviceID)
    private(set) var volumes: [AudioDeviceID: Float] = [:]

    /// Mute states for all tracked output devices (keyed by AudioDeviceID)
    private(set) var muteStates: [AudioDeviceID: Bool] = [:]

    /// The current default output device ID
    private(set) var defaultDeviceID: AudioDeviceID = .unknown

    /// The current default output device UID (cached to avoid redundant Core Audio calls)
    private(set) var defaultDeviceUID: String?

    /// The current system output device ID (for alerts, notifications, system sounds)
    private(set) var systemDeviceID: AudioDeviceID = .unknown

    /// The current system output device UID
    private(set) var systemDeviceUID: String?

    /// Whether system sounds should follow the macOS default output device
    private(set) var isSystemFollowingDefault: Bool = true

    /// Called when any device's volume changes (deviceID, newVolume)
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?

    /// Called when any device's mute state changes (deviceID, isMuted)
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?

    /// Called when the default output device changes (newDeviceUID)
    var onDefaultDeviceChanged: ((String) -> Void)?

    private let deviceMonitor: AudioDeviceMonitor
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DeviceVolumeMonitor")

    /// Volume listeners for each tracked device
    private var volumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    /// Mute listeners for each tracked device
    private var muteListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Flag to control the recursive observation loop
    private var isObservingDeviceList = false

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var systemDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    init(deviceMonitor: AudioDeviceMonitor, settingsManager: SettingsManager) {
        self.deviceMonitor = deviceMonitor
        self.settingsManager = settingsManager
    }

    func start() {
        guard defaultDeviceListenerBlock == nil else { return }

        logger.debug("Starting device volume monitor")

        // Load persisted "follow default" state for system sounds
        isSystemFollowingDefault = settingsManager.isSystemSoundsFollowingDefault

        // Read initial default device
        refreshDefaultDevice()

        // Read initial system device
        refreshSystemDevice()

        // Read volumes for all devices and set up listeners
        refreshDeviceListeners()

        // Listen for default output device changes
        defaultDeviceListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultDeviceChanged()
            }
        }

        let defaultDeviceStatus = AudioObjectAddPropertyListenerBlock(
            .system,
            &defaultDeviceAddress,
            .main,
            defaultDeviceListenerBlock!
        )

        if defaultDeviceStatus != noErr {
            logger.error("Failed to add default device listener: \(defaultDeviceStatus)")
        }

        // Listen for system output device changes
        systemDeviceListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDeviceChanged()
            }
        }

        let systemDeviceStatus = AudioObjectAddPropertyListenerBlock(
            .system,
            &systemDeviceAddress,
            .main,
            systemDeviceListenerBlock!
        )

        if systemDeviceStatus != noErr {
            logger.error("Failed to add system device listener: \(systemDeviceStatus)")
        }

        // Observe device list changes from deviceMonitor using withObservationTracking
        startObservingDeviceList()
    }

    func stop() {
        logger.debug("Stopping device volume monitor")

        // Stop the device list observation loop
        isObservingDeviceList = false

        // Remove default device listener
        if let block = defaultDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &defaultDeviceAddress, .main, block)
            defaultDeviceListenerBlock = nil
        }

        // Remove system device listener
        if let block = systemDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &systemDeviceAddress, .main, block)
            systemDeviceListenerBlock = nil
        }

        // Remove all volume listeners
        for deviceID in Array(volumeListeners.keys) {
            removeVolumeListener(for: deviceID)
        }

        // Remove all mute listeners
        for deviceID in Array(muteListeners.keys) {
            removeMuteListener(for: deviceID)
        }

        volumes.removeAll()
        muteStates.removeAll()
        systemDeviceID = .unknown
        systemDeviceUID = nil
    }

    /// Sets the volume for a specific device
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) {
        guard deviceID.isValid else {
            logger.warning("Cannot set volume: invalid device ID")
            return
        }

        let success = deviceID.setOutputVolumeScalar(volume)
        if success {
            volumes[deviceID] = volume
        } else {
            logger.warning("Failed to set volume on device \(deviceID)")
        }
    }

    /// Sets a device as the macOS system default output device
    func setDefaultDevice(_ deviceID: AudioDeviceID) {
        guard deviceID.isValid else {
            logger.warning("Cannot set default device: invalid device ID")
            return
        }

        do {
            try AudioDeviceID.setDefaultOutputDevice(deviceID)
            logger.debug("Set default output device to \(deviceID)")
        } catch {
            logger.error("Failed to set default device: \(error.localizedDescription)")
        }
    }

    /// Sets the mute state for a specific device
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) {
        guard deviceID.isValid else {
            logger.warning("Cannot set mute: invalid device ID")
            return
        }

        let success = deviceID.setMuteState(muted)
        if success {
            muteStates[deviceID] = muted
        } else {
            logger.warning("Failed to set mute on device \(deviceID)")
        }
    }

    // MARK: - Private Methods

    private func refreshDefaultDevice() {
        do {
            let newDeviceID: AudioDeviceID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultOutputDevice,
                defaultValue: AudioDeviceID.unknown
            )

            if newDeviceID.isValid {
                defaultDeviceID = newDeviceID
                defaultDeviceUID = try? newDeviceID.readDeviceUID()
                logger.debug("Default device ID: \(self.defaultDeviceID), UID: \(self.defaultDeviceUID ?? "nil")")
            } else {
                logger.warning("Default output device is invalid")
                defaultDeviceID = .unknown
                defaultDeviceUID = nil
            }

        } catch {
            logger.error("Failed to read default output device: \(error.localizedDescription)")
        }
    }

    private func handleDefaultDeviceChanged() {
        let oldUID = defaultDeviceUID
        logger.debug("Default output device changed")
        refreshDefaultDevice()
        if let newUID = defaultDeviceUID, newUID != oldUID {
            onDefaultDeviceChanged?(newUID)

            // If system sounds follows default, update it too
            if isSystemFollowingDefault && defaultDeviceID.isValid {
                setSystemDevice(defaultDeviceID)
                logger.debug("System sounds followed default to new device")
            }
        }
    }

    private func refreshSystemDevice() {
        do {
            let newDeviceID: AudioDeviceID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultSystemOutputDevice,
                defaultValue: AudioDeviceID.unknown
            )

            if newDeviceID.isValid {
                systemDeviceID = newDeviceID
                systemDeviceUID = try? newDeviceID.readDeviceUID()
                logger.debug("System device ID: \(self.systemDeviceID), UID: \(self.systemDeviceUID ?? "nil")")
            } else {
                logger.warning("System output device is invalid")
                systemDeviceID = .unknown
                systemDeviceUID = nil
            }

        } catch {
            logger.error("Failed to read system output device: \(error.localizedDescription)")
        }
    }

    private func handleSystemDeviceChanged() {
        logger.debug("System output device changed")
        refreshSystemDevice()
    }

    /// Sets the system output device (for alerts, notifications, system sounds)
    func setSystemDevice(_ deviceID: AudioDeviceID) {
        guard deviceID.isValid else {
            logger.warning("Cannot set system device: invalid device ID")
            return
        }

        do {
            try AudioDeviceID.setSystemOutputDevice(deviceID)
            logger.debug("Set system output device to \(deviceID)")
        } catch {
            logger.error("Failed to set system device: \(error.localizedDescription)")
        }
    }

    /// Sets system sounds to follow macOS default output device
    func setSystemFollowDefault() {
        isSystemFollowingDefault = true
        settingsManager.setSystemSoundsFollowDefault(true)

        // Immediately sync to current default
        if defaultDeviceID.isValid {
            setSystemDevice(defaultDeviceID)
        }
        logger.debug("System sounds now following default")
    }

    /// Sets system sounds to explicit device (stops following default)
    func setSystemDeviceExplicit(_ deviceID: AudioDeviceID) {
        isSystemFollowingDefault = false
        settingsManager.setSystemSoundsFollowDefault(false)
        setSystemDevice(deviceID)
        logger.debug("System sounds set to explicit device: \(deviceID)")
    }

    /// Synchronizes volume and mute listeners with the current device list from deviceMonitor
    private func refreshDeviceListeners() {
        let currentDeviceIDs = Set(deviceMonitor.outputDevices.map(\.id))
        let trackedVolumeIDs = Set(volumeListeners.keys)
        let trackedMuteIDs = Set(muteListeners.keys)

        // Add listeners for new devices
        let newDeviceIDs = currentDeviceIDs.subtracting(trackedVolumeIDs)
        for deviceID in newDeviceIDs {
            addVolumeListener(for: deviceID)
            addMuteListener(for: deviceID)
        }

        // Remove listeners for stale devices
        let staleVolumeIDs = trackedVolumeIDs.subtracting(currentDeviceIDs)
        for deviceID in staleVolumeIDs {
            removeVolumeListener(for: deviceID)
            volumes.removeValue(forKey: deviceID)
        }

        let staleMuteIDs = trackedMuteIDs.subtracting(currentDeviceIDs)
        for deviceID in staleMuteIDs {
            removeMuteListener(for: deviceID)
            muteStates.removeValue(forKey: deviceID)
        }

        // Read volumes and mute states for all current devices
        readAllStates()
    }

    private func addVolumeListener(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        guard volumeListeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleVolumeChanged(for: deviceID)
            }
        }

        volumeListeners[deviceID] = block

        var address = volumeAddress
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            .main,
            block
        )

        if status != noErr {
            logger.warning("Failed to add volume listener for device \(deviceID): \(status)")
            volumeListeners.removeValue(forKey: deviceID)
        }
    }

    private func removeVolumeListener(for deviceID: AudioDeviceID) {
        guard let block = volumeListeners[deviceID] else { return }

        var address = volumeAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        volumeListeners.removeValue(forKey: deviceID)
    }

    private func handleVolumeChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        let newVolume = deviceID.readOutputVolumeScalar()
        volumes[deviceID] = newVolume
        onVolumeChanged?(deviceID, newVolume)
        logger.debug("Volume changed for device \(deviceID): \(newVolume)")
    }

    private func addMuteListener(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        guard muteListeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleMuteChanged(for: deviceID)
            }
        }

        muteListeners[deviceID] = block

        var address = muteAddress
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            .main,
            block
        )

        if status != noErr {
            logger.warning("Failed to add mute listener for device \(deviceID): \(status)")
            muteListeners.removeValue(forKey: deviceID)
        }
    }

    private func removeMuteListener(for deviceID: AudioDeviceID) {
        guard let block = muteListeners[deviceID] else { return }

        var address = muteAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        muteListeners.removeValue(forKey: deviceID)
    }

    private func handleMuteChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        let newMuteState = deviceID.readMuteState()
        muteStates[deviceID] = newMuteState
        onMuteChanged?(deviceID, newMuteState)
        logger.debug("Mute changed for device \(deviceID): \(newMuteState)")
    }

    /// Reads the current volume and mute state for all tracked devices.
    /// For Bluetooth devices, schedules a delayed re-read because the HAL may report
    /// default volume (1.0) for 50-200ms after the device appears.
    private func readAllStates() {
        for device in deviceMonitor.outputDevices {
            let volume = device.id.readOutputVolumeScalar()
            volumes[device.id] = volume

            let muted = device.id.readMuteState()
            muteStates[device.id] = muted

            // Bluetooth devices may not have valid volume immediately after appearing.
            // The HAL returns 1.0 (default) until the BT firmware handshake completes.
            // Schedule a delayed re-read to get the actual volume.
            let transportType = device.id.readTransportType()
            if transportType == .bluetooth || transportType == .bluetoothLE {
                let deviceID = device.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, self.volumes.keys.contains(deviceID) else { return }
                    let confirmedVolume = deviceID.readOutputVolumeScalar()
                    self.volumes[deviceID] = confirmedVolume
                    let confirmedMute = deviceID.readMuteState()
                    self.muteStates[deviceID] = confirmedMute
                    self.logger.debug("Bluetooth device \(deviceID) re-read volume: \(confirmedVolume), muted: \(confirmedMute)")
                }
            }
        }
    }

    /// Starts observing deviceMonitor.outputDevices for changes
    private func startObservingDeviceList() {
        guard !isObservingDeviceList else { return }
        isObservingDeviceList = true

        func observe() {
            guard isObservingDeviceList else { return }
            withObservationTracking {
                _ = self.deviceMonitor.outputDevices
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isObservingDeviceList else { return }
                    self.logger.debug("Device list changed, refreshing volume listeners")
                    self.refreshDeviceListeners()
                    observe()
                }
            }
        }
        observe()
    }

    deinit {
        // Note: Can't call stop() here due to MainActor isolation
        // Listeners will be cleaned up when the process exits
    }
}
