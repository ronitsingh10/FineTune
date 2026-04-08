// FineTune/Audio/Monitors/DeviceVolumeMonitor.swift
import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class DeviceVolumeMonitor: DeviceVolumeProviding {
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

    /// System alert volume (0.0–1.0), matches System Settings > Sound > Alert volume.
    /// Read/written via AppleScript since no CoreAudio property exists for this.
    private(set) var alertVolume: Float = 1.0

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
    private var pendingBluetoothOutputConfirmTasks: [AudioDeviceID: Task<Void, Never>] = [:]
    private var pendingBluetoothInputConfirmTasks: [AudioDeviceID: Task<Void, Never>] = [:]

    /// Debounced volume log tasks — log settled value at .info after 300ms instead of every change at .debug
    private var pendingVolumeLogTasks: [AudioDeviceID: Task<Void, Never>] = [:]

    /// Debounce task for alert volume writes (NSAppleScript is heavy — throttle during drag)
    private var alertVolumeDebounceTask: Task<Void, Never>?

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
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var defaultInputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var inputVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var inputMuteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput,
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

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        guard deviceID.isValid else { return .software }

        if deviceID.hasOutputVolumeControl() {
            return .hardware
        }

        #if !APP_STORE
        if let ddcController {
            if !ddcController.probeCompleted {
                return .hardware
            }
            if ddcController.isDDCBacked(deviceID) {
                return .ddc
            }
        }
        #endif

        return .software
    }

    func outputProcessingGain(for deviceID: AudioDeviceID) -> Float {
        guard outputVolumeBackend(for: deviceID) == .software else { return 1.0 }
        if muteStates[deviceID] ?? false { return 0.0 }
        return volumes[deviceID] ?? 1.0
    }

    func refreshOutputDeviceStates() {
        readAllStates()
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

        // Read initial alert volume
        refreshAlertVolume()

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

        cancelAllBluetoothConfirmationTasks()
        cancelAllVolumeLogTasks()

        volumes.removeAll()
        muteStates.removeAll()
        systemDeviceID = .unknown
        systemDeviceUID = nil

        inputVolumes.removeAll()
        inputMuteStates.removeAll()
        defaultInputDeviceID = .unknown
        defaultInputDeviceUID = nil
    }

    /// Threshold clamp: sub-1% scalar → true silence.
    /// On audio-tapered devices, scalar 0.01 ≈ -99 dB (empirically measured on built-in output).
    /// On software-volume devices, 0.01 gain = -40 dB (linear). Either way, inaudible.
    private func clampedVolume(_ volume: Float) -> Float {
        volume < 0.01 ? 0 : volume
    }

    /// Sets the volume for a specific device
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) {
        guard deviceID.isValid else {
            logger.warning("Cannot set volume: invalid device ID")
            return
        }

        let clamped = clampedVolume(volume)
        switch outputVolumeBackend(for: deviceID) {
        case .hardware:
            let success = deviceID.setOutputVolumeScalar(clamped)
            if success {
                volumes[deviceID] = clamped
            } else {
                logger.warning("Failed to set volume on device \(deviceID)")
            }

        case .ddc:
            #if !APP_STORE
            if let ddcController {
                let ddcVolume = Int(round(clamped * 100))
                ddcController.setVolume(for: deviceID, to: ddcVolume)
                volumes[deviceID] = clamped
            } else {
                logger.warning("Failed to set DDC volume on device \(deviceID)")
            }
            #else
            logger.warning("DDC volume not available on device \(deviceID)")
            #endif

        case .software:
            guard let deviceUID = outputDeviceUID(for: deviceID) else {
                logger.warning("Cannot persist software volume: missing device UID for \(deviceID)")
                return
            }
            volumes[deviceID] = clamped
            settingsManager.setSoftwareDeviceVolume(for: deviceUID, to: clamped)
            onVolumeChanged?(deviceID, clamped)
        }
    }

    /// Sets a device as the macOS system default output device
    @discardableResult
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID.isValid else {
            logger.warning("Cannot set default device: invalid device ID")
            return false
        }

        do {
            try AudioDeviceID.setDefaultOutputDevice(deviceID)
            logger.debug("Set default output device to \(deviceID)")
            return true
        } catch {
            logger.error("Failed to set default device: \(error.localizedDescription)")
            return false
        }
    }

    /// Sets the mute state for a specific device
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) {
        guard deviceID.isValid else {
            logger.warning("Cannot set mute: invalid device ID")
            return
        }

        switch outputVolumeBackend(for: deviceID) {
        case .hardware:
            let success = deviceID.setMuteState(muted)
            if success {
                muteStates[deviceID] = muted
            } else {
                logger.warning("Failed to set mute on device \(deviceID)")
            }

        case .ddc:
            #if !APP_STORE
            if let ddcController {
                if muted {
                    ddcController.mute(for: deviceID)
                } else {
                    ddcController.unmute(for: deviceID)
                }
                muteStates[deviceID] = muted
            } else {
                logger.warning("Failed to set DDC mute on device \(deviceID)")
            }
            #else
            logger.warning("DDC mute not available on device \(deviceID)")
            #endif

        case .software:
            guard let deviceUID = outputDeviceUID(for: deviceID) else {
                logger.warning("Cannot persist software mute: missing device UID for \(deviceID)")
                return
            }

            if muted {
                let currentVisibleVolume = volumes[deviceID] ?? settingsManager.getSoftwareDeviceVolume(for: deviceUID) ?? 1.0
                if currentVisibleVolume > 0 {
                    settingsManager.setSoftwareDeviceSavedVolume(for: deviceUID, to: currentVisibleVolume)
                }
                settingsManager.setSoftwareDeviceMuteState(for: deviceUID, to: true)
                settingsManager.setSoftwareDeviceVolume(for: deviceUID, to: 0)
                volumes[deviceID] = 0
                muteStates[deviceID] = true
                onVolumeChanged?(deviceID, 0)
                onMuteChanged?(deviceID, true)
            } else {
                settingsManager.setSoftwareDeviceMuteState(for: deviceUID, to: false)

                let currentVisibleVolume = volumes[deviceID] ?? settingsManager.getSoftwareDeviceVolume(for: deviceUID) ?? 0
                if currentVisibleVolume == 0 {
                    let restoredVolume = settingsManager.getSoftwareDeviceSavedVolume(for: deviceUID) ?? 0.5
                    settingsManager.setSoftwareDeviceVolume(for: deviceUID, to: restoredVolume)
                    volumes[deviceID] = restoredVolume
                    onVolumeChanged?(deviceID, restoredVolume)
                }

                muteStates[deviceID] = false
                onMuteChanged?(deviceID, false)
            }
        }
    }

    #if !APP_STORE
    /// Re-reads volume/mute states after DDC probe discovers (or loses) displays.
    func refreshAfterDDCProbe() {
        refreshOutputDeviceStates()
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
    @discardableResult
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID.isValid else {
            logger.warning("Cannot set default input device: invalid device ID")
            return false
        }

        do {
            try AudioDeviceID.setDefaultInputDevice(deviceID)
            logger.debug("Set default input device to \(deviceID)")
            return true
        } catch {
            logger.error("Failed to set default input device: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Methods

    private func refreshDefaultDevice() {
        do {
            let newDeviceID = try AudioDeviceID.readDefaultOutputDevice()

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

            // If system sounds follows default, update it too.
            // Re-read default first — the callback above may have overridden it
            // (e.g., AudioEngine enforcing priority-based routing).
            if isSystemFollowingDefault {
                refreshDefaultDevice()
                if defaultDeviceID.isValid {
                    setSystemDevice(defaultDeviceID)
                    refreshSystemDevice()
                    if systemDeviceUID != defaultDeviceUID {
                        logger.warning("Failed to sync system sounds to new default device")
                    } else {
                        logger.debug("System sounds followed default to new device")
                    }
                }
            }
        }
    }

    private func refreshSystemDevice() {
        do {
            let newDeviceID = try AudioDeviceID.readSystemOutputDevice()

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

    // MARK: - Alert Volume

    /// Reads the current system alert volume via AppleScript.
    /// No CoreAudio property exists for alert volume — AppleScript is the canonical API.
    /// Safe to call periodically for live sync; skip if a debounced write is pending.
    func refreshAlertVolume() {
        guard alertVolumeDebounceTask == nil else { return }

        let script = NSAppleScript(source: "get alert volume of (get volume settings)")
        var error: NSDictionary?
        if let result = script?.executeAndReturnError(&error) {
            let pct = Int(result.int32Value)
            alertVolume = Float(pct) / 100.0
        }
    }

    /// Sets the system alert volume (same as System Settings > Sound > Alert volume).
    /// Updates the local property immediately for responsive UI, then debounces the
    /// AppleScript call by 100ms to avoid blocking during rapid slider drags.
    /// - Parameter volume: Alert volume from 0.0 to 1.0
    func setAlertVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        let pct = Int(round(clamped * 100))
        let newVolume = Float(pct) / 100.0

        // Deduplicate: @Observable update → SwiftUI re-render → Slider re-sends same value
        // through Binding set. Without this guard, each re-render cancels the pending debounce
        // task before the 100ms elapses, so the NSAppleScript write never fires.
        guard newVolume != alertVolume else { return }

        alertVolume = newVolume

        alertVolumeDebounceTask?.cancel()
        alertVolumeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            let script = NSAppleScript(source: "set volume alert volume \(pct)")
            var scriptError: NSDictionary?
            script?.executeAndReturnError(&scriptError)
            if let scriptError {
                self.logger.warning("Failed to set alert volume: \(scriptError)")
            }
            self.alertVolumeDebounceTask = nil
        }
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
            cancelBluetoothOutputConfirmation(for: deviceID)
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
            mScope: kAudioObjectPropertyScopeOutput,
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
            mScope: kAudioObjectPropertyScopeOutput,
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
        guard let block = volumeListeners.removeValue(forKey: deviceID) else { return }

        let status: OSStatus
        if let registeredAddr = registeredVolumeAddresses.removeValue(forKey: deviceID) {
            var addr = registeredAddr
            status = AudioObjectRemovePropertyListenerBlock(deviceID, &addr, .main, block)
        } else {
            var address = volumeAddress
            status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
        // Tolerate kAudioHardwareBadObjectError (-66680): device already destroyed
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove volume listener for device \(deviceID): \(status)")
        }
    }

    private func handleVolumeChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }

        if outputVolumeBackend(for: deviceID) == .software { return }

        #if !APP_STORE
        // DDC-backed devices don't have real CoreAudio volume changes;
        // ignore HAL callbacks (they always report 1.0)
        if let ddcController, ddcController.isDDCBacked(deviceID) { return }
        #endif

        let newVolume = clampedVolume(deviceID.readOutputVolumeScalar())

        // Deduplicate: HAL often fires L/R channel notifications for the same volume value.
        // Both values come from the same CoreAudio API (not computed), so == is safe for Float32.
        if let currentVolume = volumes[deviceID], currentVolume == newVolume { return }

        volumes[deviceID] = newVolume
        onVolumeChanged?(deviceID, newVolume)

        // Debounced logging: log the settled value at .info after 300ms instead of every tick
        pendingVolumeLogTasks[deviceID]?.cancel()
        pendingVolumeLogTasks[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.pendingVolumeLogTasks.removeValue(forKey: deviceID)
            let settled = self.volumes[deviceID] ?? newVolume
            self.logger.info("Volume settled for device \(deviceID): \(settled)")
        }
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
        guard let block = muteListeners.removeValue(forKey: deviceID) else { return }

        var address = muteAddress
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove mute listener for device \(deviceID): \(status)")
        }
    }

    private func handleMuteChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        if outputVolumeBackend(for: deviceID) == .software { return }
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
            // Skip devices that HAL reports as dead (mid-disconnect)
            guard device.id.isDeviceAlive() else { continue }

            let backend = outputVolumeBackend(for: device.id)

            if backend == .software {
                let muted = settingsManager.getSoftwareDeviceMuteState(for: device.uid)
                let defaultVolume: Float = muted ? 0 : 1.0
                let visibleVolume = settingsManager.getSoftwareDeviceVolume(for: device.uid) ?? defaultVolume
                volumes[device.id] = clampedVolume(visibleVolume)
                muteStates[device.id] = muted
                continue
            }

            #if !APP_STORE
            // For DDC-backed devices, use cached DDC volume instead of CoreAudio
            if backend == .ddc, let ddcController {
                if let ddcVolume = ddcController.getVolume(for: device.id) {
                    volumes[device.id] = Float(ddcVolume) / 100.0
                } else {
                    volumes[device.id] = 0.5
                }
                muteStates[device.id] = ddcController.isMuted(for: device.id)
                continue
            }
            #endif

            let volume = clampedVolume(device.id.readOutputVolumeScalar())
            volumes[device.id] = volume

            let muted = device.id.readMuteState()
            muteStates[device.id] = muted

            // Bluetooth devices may not have valid volume immediately after appearing.
            // The HAL returns 1.0 (default) until the BT firmware handshake completes.
            // Schedule a delayed re-read to get the actual volume.
            let transportType = device.id.readTransportType()
            if transportType == .bluetooth || transportType == .bluetoothLE {
                scheduleBluetoothOutputConfirmation(for: device.id)
            }
        }
    }

    private func outputDeviceUID(for deviceID: AudioDeviceID) -> String? {
        deviceMonitor.device(for: deviceID)?.uid
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
            let newDeviceID = try AudioDeviceID.readDefaultInputDevice()

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
            cancelBluetoothInputConfirmation(for: deviceID)
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
        guard let block = inputVolumeListeners.removeValue(forKey: deviceID) else { return }

        var address = inputVolumeAddress
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove input volume listener for device \(deviceID): \(status)")
        }
    }

    private func handleInputVolumeChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        let newVolume = deviceID.readInputVolumeScalar()

        // Deduplicate: same logic as output volume
        if let currentVolume = inputVolumes[deviceID], currentVolume == newVolume { return }

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
        guard let block = inputMuteListeners.removeValue(forKey: deviceID) else { return }

        var address = inputMuteAddress
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove input mute listener for device \(deviceID): \(status)")
        }
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
            // Skip devices that HAL reports as dead (mid-disconnect)
            guard device.id.isDeviceAlive() else { continue }

            let volume = device.id.readInputVolumeScalar()
            inputVolumes[device.id] = volume

            let muted = device.id.readInputMuteState()
            inputMuteStates[device.id] = muted

            // Bluetooth devices may not have valid volume immediately after appearing
            let transportType = device.id.readTransportType()
            if transportType == .bluetooth || transportType == .bluetoothLE {
                scheduleBluetoothInputConfirmation(for: device.id)
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

    // MARK: - Bluetooth Confirmation Tasks

    /// Schedules a delayed re-read of volume/mute for a Bluetooth output device.
    /// Cancels any existing task for the same device to avoid stale reads.
    private func scheduleBluetoothOutputConfirmation(for deviceID: AudioDeviceID) {
        pendingBluetoothOutputConfirmTasks[deviceID]?.cancel()
        pendingBluetoothOutputConfirmTasks[deviceID] = Task { @MainActor [weak self] in
            defer { self?.pendingBluetoothOutputConfirmTasks.removeValue(forKey: deviceID) }
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.volumes.keys.contains(deviceID) else { return }
            let confirmedVolume = self.clampedVolume(deviceID.readOutputVolumeScalar())
            let confirmedMute = deviceID.readMuteState()
            self.volumes[deviceID] = confirmedVolume
            self.muteStates[deviceID] = confirmedMute
            self.logger.debug("Bluetooth device \(deviceID) confirmed volume: \(confirmedVolume), muted: \(confirmedMute)")
        }
    }

    /// Cancels a pending Bluetooth output confirmation task for a specific device.
    private func cancelBluetoothOutputConfirmation(for deviceID: AudioDeviceID) {
        pendingBluetoothOutputConfirmTasks.removeValue(forKey: deviceID)?.cancel()
    }

    /// Schedules a delayed re-read of volume/mute for a Bluetooth input device.
    /// Cancels any existing task for the same device to avoid stale reads.
    private func scheduleBluetoothInputConfirmation(for deviceID: AudioDeviceID) {
        pendingBluetoothInputConfirmTasks[deviceID]?.cancel()
        pendingBluetoothInputConfirmTasks[deviceID] = Task { @MainActor [weak self] in
            defer { self?.pendingBluetoothInputConfirmTasks.removeValue(forKey: deviceID) }
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.inputVolumes.keys.contains(deviceID) else { return }
            let confirmedVolume = deviceID.readInputVolumeScalar()
            let confirmedMute = deviceID.readInputMuteState()
            self.inputVolumes[deviceID] = confirmedVolume
            self.inputMuteStates[deviceID] = confirmedMute
            self.logger.debug("Bluetooth input device \(deviceID) confirmed volume: \(confirmedVolume), muted: \(confirmedMute)")
        }
    }

    /// Cancels a pending Bluetooth input confirmation task for a specific device.
    private func cancelBluetoothInputConfirmation(for deviceID: AudioDeviceID) {
        pendingBluetoothInputConfirmTasks.removeValue(forKey: deviceID)?.cancel()
    }

    /// Cancels all pending Bluetooth confirmation tasks (called from stop()).
    private func cancelAllBluetoothConfirmationTasks() {
        for (_, task) in pendingBluetoothOutputConfirmTasks { task.cancel() }
        pendingBluetoothOutputConfirmTasks.removeAll()
        for (_, task) in pendingBluetoothInputConfirmTasks { task.cancel() }
        pendingBluetoothInputConfirmTasks.removeAll()
    }

    /// Cancels all pending volume log debounce tasks (called from stop()).
    private func cancelAllVolumeLogTasks() {
        for (_, task) in pendingVolumeLogTasks { task.cancel() }
        pendingVolumeLogTasks.removeAll()
    }

}
