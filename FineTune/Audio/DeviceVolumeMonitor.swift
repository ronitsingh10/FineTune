// FineTune/Audio/DeviceVolumeMonitor.swift
import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class DeviceVolumeMonitor {
    /// Virtual main volume selector. The constant name is legacy (`AudioHardwareService*`)
    /// but this selector is still the correct HAL property for system-style main volume.
    private static let virtualMainVolumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    // MARK: - Output Device State

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

    /// Called when any output device's volume changes (deviceID, newVolume)
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?

    /// Called when any output device's mute state changes (deviceID, isMuted)
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?

    /// Called when the default output device changes (newDeviceUID)
    var onDefaultDeviceChanged: ((String) -> Void)?

    // MARK: - Input Device State

    /// Volumes for all tracked input devices (keyed by AudioDeviceID)
    private(set) var inputVolumes: [AudioDeviceID: Float] = [:]

    /// Mute states for all tracked input devices (keyed by AudioDeviceID)
    private(set) var inputMuteStates: [AudioDeviceID: Bool] = [:]

    /// The current default input device ID
    private(set) var defaultInputDeviceID: AudioDeviceID = .unknown

    /// The current default input device UID (cached to avoid redundant Core Audio calls)
    private(set) var defaultInputDeviceUID: String?

    /// Called when any input device's volume changes (deviceID, newVolume)
    var onInputVolumeChanged: ((AudioDeviceID, Float) -> Void)?

    /// Called when any input device's mute state changes (deviceID, isMuted)
    var onInputMuteChanged: ((AudioDeviceID, Bool) -> Void)?

    /// Called when the default input device changes (newDeviceUID)
    var onDefaultInputDeviceChanged: ((String) -> Void)?

    private let deviceMonitor: AudioDeviceMonitor
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DeviceVolumeMonitor")

    #if !APP_STORE
    private let ddcController: DDCController?
    #endif

    /// Volume listeners for each tracked output device
    private var volumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    /// Mute listeners for each tracked output device
    private var muteListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Volume listeners for each tracked input device
    private var inputVolumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    /// Mute listeners for each tracked input device
    private var inputMuteListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Tracks which volume property address was successfully registered per device (for fallback removal)
    private var registeredVolumeAddresses: [AudioDeviceID: AudioObjectPropertyAddress] = [:]

    /// Flag to control the recursive observation loop
    private var isObservingDeviceList = false
    private var isObservingInputDeviceList = false

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
        mSelector: DeviceVolumeMonitor.virtualMainVolumeSelector,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var defaultInputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var inputVolumeAddress = AudioObjectPropertyAddress(
        mSelector: DeviceVolumeMonitor.virtualMainVolumeSelector,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var inputMuteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    #if !APP_STORE
    init(deviceMonitor: AudioDeviceMonitor, settingsManager: SettingsManager, ddcController: DDCController? = nil) {
        self.deviceMonitor = deviceMonitor
        self.settingsManager = settingsManager
        self.ddcController = ddcController
    }
    #else
    init(deviceMonitor: AudioDeviceMonitor, settingsManager: SettingsManager) {
        self.deviceMonitor = deviceMonitor
        self.settingsManager = settingsManager
    }
    #endif

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

        // Input device monitoring
        refreshDefaultInputDevice()
        refreshInputDeviceListeners()

        // Listen for default input device changes
        defaultInputDeviceListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged()
            }
        }

        let defaultInputDeviceStatus = AudioObjectAddPropertyListenerBlock(
            .system,
            &defaultInputDeviceAddress,
            .main,
            defaultInputDeviceListenerBlock!
        )

        if defaultInputDeviceStatus != noErr {
            logger.error("Failed to add default input device listener: \(defaultInputDeviceStatus)")
        }

        startObservingInputDeviceList()

        // Validate system sound state matches persisted preference
        validateSystemSoundState()
    }

    func stop() {
        logger.debug("Stopping device volume monitor")

        // Stop the device list observation loops
        isObservingDeviceList = false
        isObservingInputDeviceList = false

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

        // Remove default input device listener
        if let block = defaultInputDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &defaultInputDeviceAddress, .main, block)
            defaultInputDeviceListenerBlock = nil
        }

        // Remove all output volume listeners
        for deviceID in Array(volumeListeners.keys) {
            removeVolumeListener(for: deviceID)
        }

        // Remove all output mute listeners
        for deviceID in Array(muteListeners.keys) {
            removeMuteListener(for: deviceID)
        }

        // Remove all input volume listeners
        for deviceID in Array(inputVolumeListeners.keys) {
            removeInputVolumeListener(for: deviceID)
        }

        // Remove all input mute listeners
        for deviceID in Array(inputMuteListeners.keys) {
            removeInputMuteListener(for: deviceID)
        }

        volumes.removeAll()
        muteStates.removeAll()
        systemDeviceID = .unknown
        systemDeviceUID = nil

        inputVolumes.removeAll()
        inputMuteStates.removeAll()
        defaultInputDeviceID = .unknown
        defaultInputDeviceUID = nil
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
            #if !APP_STORE
            if let ddcController, ddcController.isDDCBacked(deviceID) {
                let ddcVolume = Int(round(volume * 100))
                ddcController.setVolume(for: deviceID, to: ddcVolume)
                volumes[deviceID] = volume
            } else {
                logger.warning("Failed to set volume on device \(deviceID)")
            }
            #else
            logger.warning("Failed to set volume on device \(deviceID)")
            #endif
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
            #if !APP_STORE
            if let ddcController, ddcController.isDDCBacked(deviceID) {
                if muted {
                    ddcController.mute(for: deviceID)
                } else {
                    ddcController.unmute(for: deviceID)
                }
                muteStates[deviceID] = muted
            } else {
                logger.warning("Failed to set mute on device \(deviceID)")
            }
            #else
            logger.warning("Failed to set mute on device \(deviceID)")
            #endif
        }
    }

    #if !APP_STORE
    /// Re-reads volume/mute states after DDC probe discovers (or loses) displays.
    func refreshAfterDDCProbe() {
        readAllStates()
    }
    #endif

    // MARK: - Input Device Control

    /// Sets the volume for a specific input device
    func setInputVolume(for deviceID: AudioDeviceID, to volume: Float) {
        guard deviceID.isValid else {
            logger.warning("Cannot set input volume: invalid device ID")
            return
        }

        let success = deviceID.setInputVolumeScalar(volume)
        if success {
            inputVolumes[deviceID] = volume
        } else {
            logger.warning("Failed to set input volume on device \(deviceID)")
        }
    }

    /// Sets the mute state for a specific input device
    func setInputMute(for deviceID: AudioDeviceID, to muted: Bool) {
        guard deviceID.isValid else {
            logger.warning("Cannot set input mute: invalid device ID")
            return
        }

        let success = deviceID.setInputMuteState(muted)
        if success {
            inputMuteStates[deviceID] = muted
        } else {
            logger.warning("Failed to set input mute on device \(deviceID)")
        }
    }

    /// Sets a device as the macOS system default input device
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        guard deviceID.isValid else {
            logger.warning("Cannot set default input device: invalid device ID")
            return
        }

        do {
            try AudioDeviceID.setDefaultInputDevice(deviceID)
            logger.debug("Set default input device to \(deviceID)")
        } catch {
            logger.error("Failed to set default input device: \(error.localizedDescription)")
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
                // Verify the operation succeeded
                refreshSystemDevice()
                if systemDeviceUID != defaultDeviceUID {
                    logger.warning("Failed to sync system sounds to new default device")
                } else {
                    logger.debug("System sounds followed default to new device")
                }
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

    /// Validates that persisted system sound state matches actual macOS state on startup.
    /// If "follow default" is enabled but system device differs from default, enforces the preference.
    private func validateSystemSoundState() {
        guard defaultDeviceUID != nil, systemDeviceUID != nil else {
            logger.debug("Cannot validate system sound state: missing device UIDs")
            return
        }

        let systemMatchesDefault = (systemDeviceUID == defaultDeviceUID)

        if isSystemFollowingDefault && !systemMatchesDefault {
            // Persisted says "follow default" but actual state differs - enforce preference
            if defaultDeviceID.isValid {
                setSystemDevice(defaultDeviceID)
                refreshSystemDevice()
                if systemDeviceUID != defaultDeviceUID {
                    logger.warning("Startup: failed to enforce system sounds to follow default")
                } else {
                    logger.info("Startup: enforced system sounds to follow default device")
                }
            }
        }
    }

    private func handleSystemDeviceChanged() {
        logger.debug("System output device changed")
        refreshSystemDevice()

        // Detect if external change broke "follow default" state
        if isSystemFollowingDefault {
            let stillFollowing = (systemDeviceUID == defaultDeviceUID)
            if !stillFollowing {
                // External change broke "follow default" - update our state
                isSystemFollowingDefault = false
                settingsManager.setSystemSoundsFollowDefault(false)
                logger.info("System device changed externally, no longer following default")
            }
        }
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

        // Add listeners for new devices (computed separately so mute retries independently)
        let newVolumeIDs = currentDeviceIDs.subtracting(trackedVolumeIDs)
        let newMuteIDs = currentDeviceIDs.subtracting(trackedMuteIDs)
        for deviceID in newVolumeIDs {
            addVolumeListener(for: deviceID)
        }
        for deviceID in newMuteIDs {
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

        // Try VirtualMainVolume first (preferred — matches system slider)
        var address = volumeAddress
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            .main,
            block
        )

        if status == noErr {
            return
        }

        // Fallback 1: kAudioDevicePropertyVolumeScalar element 0 (master)
        var fallbackAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let fallback1Status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &fallbackAddr,
            .main,
            block
        )

        if fallback1Status == noErr {
            registeredVolumeAddresses[deviceID] = fallbackAddr
            logger.debug("Volume listener fallback to VolumeScalar element 0 for device \(deviceID)")
            return
        }

        // Fallback 2: kAudioDevicePropertyVolumeScalar element 1 (left channel)
        var fallbackAddr2 = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        let fallback2Status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &fallbackAddr2,
            .main,
            block
        )

        if fallback2Status == noErr {
            registeredVolumeAddresses[deviceID] = fallbackAddr2
            logger.debug("Volume listener fallback to VolumeScalar element 1 for device \(deviceID)")
            return
        }

        logger.warning("Failed to add volume listener for device \(deviceID): \(status)")
        volumeListeners.removeValue(forKey: deviceID)
    }

    private func removeVolumeListener(for deviceID: AudioDeviceID) {
        guard let block = volumeListeners[deviceID] else { return }

        if let registeredAddr = registeredVolumeAddresses.removeValue(forKey: deviceID) {
            var addr = registeredAddr
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, .main, block)
        } else {
            var address = volumeAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
        volumeListeners.removeValue(forKey: deviceID)
    }

    private func handleVolumeChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }

        #if !APP_STORE
        // DDC-backed devices don't have real CoreAudio volume changes;
        // ignore HAL callbacks (they always report 1.0)
        if let ddcController, ddcController.isDDCBacked(deviceID) { return }
        #endif

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
            #if !APP_STORE
            // For DDC-backed devices, use cached DDC volume instead of CoreAudio
            if let ddcController, ddcController.isDDCBacked(device.id) {
                if let ddcVolume = ddcController.getVolume(for: device.id) {
                    volumes[device.id] = Float(ddcVolume) / 100.0
                } else {
                    volumes[device.id] = 0.5
                }
                muteStates[device.id] = ddcController.isMuted(for: device.id)
                continue
            }
            #endif

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
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.volumes.keys.contains(deviceID) else { return }
                    let confirmedVolume = deviceID.readOutputVolumeScalar()
                    let confirmedMute = deviceID.readMuteState()
                    self.volumes[deviceID] = confirmedVolume
                    self.muteStates[deviceID] = confirmedMute
                    self.logger.debug("Bluetooth device \(deviceID) confirmed volume: \(confirmedVolume), muted: \(confirmedMute)")
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

    // MARK: - Input Device Private Methods

    private func refreshDefaultInputDevice() {
        do {
            let newDeviceID: AudioDeviceID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultInputDevice,
                defaultValue: AudioDeviceID.unknown
            )

            if newDeviceID.isValid {
                defaultInputDeviceID = newDeviceID
                defaultInputDeviceUID = try? newDeviceID.readDeviceUID()
                logger.debug("Default input device ID: \(self.defaultInputDeviceID), UID: \(self.defaultInputDeviceUID ?? "nil")")
            } else {
                logger.warning("Default input device is invalid")
                defaultInputDeviceID = .unknown
                defaultInputDeviceUID = nil
            }

        } catch {
            logger.error("Failed to read default input device: \(error.localizedDescription)")
        }
    }

    private func handleDefaultInputDeviceChanged() {
        let oldUID = defaultInputDeviceUID
        logger.debug("Default input device changed")
        refreshDefaultInputDevice()
        if let newUID = defaultInputDeviceUID, newUID != oldUID {
            onDefaultInputDeviceChanged?(newUID)
        }
    }

    /// Synchronizes input volume and mute listeners with the current input device list
    private func refreshInputDeviceListeners() {
        let currentDeviceIDs = Set(deviceMonitor.inputDevices.map(\.id))
        let trackedVolumeIDs = Set(inputVolumeListeners.keys)
        let trackedMuteIDs = Set(inputMuteListeners.keys)

        // Add listeners for new devices
        let newDeviceIDs = currentDeviceIDs.subtracting(trackedVolumeIDs)
        for deviceID in newDeviceIDs {
            addInputVolumeListener(for: deviceID)
            addInputMuteListener(for: deviceID)
        }

        // Remove listeners for stale devices
        let staleVolumeIDs = trackedVolumeIDs.subtracting(currentDeviceIDs)
        for deviceID in staleVolumeIDs {
            removeInputVolumeListener(for: deviceID)
            inputVolumes.removeValue(forKey: deviceID)
        }

        let staleMuteIDs = trackedMuteIDs.subtracting(currentDeviceIDs)
        for deviceID in staleMuteIDs {
            removeInputMuteListener(for: deviceID)
            inputMuteStates.removeValue(forKey: deviceID)
        }

        // Read volumes and mute states for all current input devices
        readAllInputStates()
    }

    private func addInputVolumeListener(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        guard inputVolumeListeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleInputVolumeChanged(for: deviceID)
            }
        }

        inputVolumeListeners[deviceID] = block

        var address = inputVolumeAddress
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            .main,
            block
        )

        if status != noErr {
            logger.warning("Failed to add input volume listener for device \(deviceID): \(status)")
            inputVolumeListeners.removeValue(forKey: deviceID)
        }
    }

    private func removeInputVolumeListener(for deviceID: AudioDeviceID) {
        guard let block = inputVolumeListeners[deviceID] else { return }

        var address = inputVolumeAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        inputVolumeListeners.removeValue(forKey: deviceID)
    }

    private func handleInputVolumeChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        let newVolume = deviceID.readInputVolumeScalar()
        inputVolumes[deviceID] = newVolume
        onInputVolumeChanged?(deviceID, newVolume)
        logger.debug("Input volume changed for device \(deviceID): \(newVolume)")
    }

    private func addInputMuteListener(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        guard inputMuteListeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleInputMuteChanged(for: deviceID)
            }
        }

        inputMuteListeners[deviceID] = block

        var address = inputMuteAddress
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            .main,
            block
        )

        if status != noErr {
            logger.warning("Failed to add input mute listener for device \(deviceID): \(status)")
            inputMuteListeners.removeValue(forKey: deviceID)
        }
    }

    private func removeInputMuteListener(for deviceID: AudioDeviceID) {
        guard let block = inputMuteListeners[deviceID] else { return }

        var address = inputMuteAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        inputMuteListeners.removeValue(forKey: deviceID)
    }

    private func handleInputMuteChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        let newMuteState = deviceID.readInputMuteState()
        inputMuteStates[deviceID] = newMuteState
        onInputMuteChanged?(deviceID, newMuteState)
        logger.debug("Input mute changed for device \(deviceID): \(newMuteState)")
    }

    /// Reads the current volume and mute state for all tracked input devices
    private func readAllInputStates() {
        for device in deviceMonitor.inputDevices {
            let volume = device.id.readInputVolumeScalar()
            inputVolumes[device.id] = volume

            let muted = device.id.readInputMuteState()
            inputMuteStates[device.id] = muted

            // Bluetooth devices may not have valid volume immediately after appearing
            let transportType = device.id.readTransportType()
            if transportType == .bluetooth || transportType == .bluetoothLE {
                let deviceID = device.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.inputVolumes.keys.contains(deviceID) else { return }
                    let confirmedVolume = deviceID.readInputVolumeScalar()
                    let confirmedMute = deviceID.readInputMuteState()
                    self.inputVolumes[deviceID] = confirmedVolume
                    self.inputMuteStates[deviceID] = confirmedMute
                    self.logger.debug("Bluetooth input device \(deviceID) confirmed volume: \(confirmedVolume), muted: \(confirmedMute)")
                }
            }
        }
    }

    /// Starts observing deviceMonitor.inputDevices for changes
    private func startObservingInputDeviceList() {
        guard !isObservingInputDeviceList else { return }
        isObservingInputDeviceList = true

        func observe() {
            guard isObservingInputDeviceList else { return }
            withObservationTracking {
                _ = self.deviceMonitor.inputDevices
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isObservingInputDeviceList else { return }
                    self.logger.debug("Input device list changed, refreshing input volume listeners")
                    self.refreshInputDeviceListeners()
                    observe()
                }
            }
        }
        observe()
    }

}
