import AudioToolbox

enum VolumeControlTier: String, Codable, Equatable {
    case hardware
    case ddc
    case software
}

@MainActor
protocol DeviceVolumeProviding: AnyObject {
    var defaultDeviceID: AudioDeviceID { get }
    var defaultDeviceUID: String? { get }
    var defaultInputDeviceUID: String? { get }
    var volumes: [AudioDeviceID: Float] { get }
    var muteStates: [AudioDeviceID: Bool] { get }

    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)? { get set }
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)? { get set }
    var onDefaultDeviceChanged: ((String) -> Void)? { get set }
    var onDefaultInputDeviceChanged: ((String) -> Void)? { get set }

    @discardableResult
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool
    @discardableResult
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool

    /// Writes a volume scalar through whichever backend this device uses.
    func setVolume(for deviceID: AudioDeviceID, to volume: Float)

    /// Writes a mute state through whichever backend this device uses.
    func setMute(for deviceID: AudioDeviceID, to muted: Bool)

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier

    /// Returns the tier that auto-detection would pick, ignoring any saved override.
    /// Used by the device detail sheet to display the "Auto: <tier>" badge.
    func autoDetectedOutputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier

    func outputProcessingGain(for deviceID: AudioDeviceID) -> Float
    func refreshOutputDeviceStates()

    /// Refreshes a single device's volume/mute state after a tier override
    /// change (manual via detail sheet or auto-promotion on write-failure).
    func applyTierOverrideChange(for deviceID: AudioDeviceID)

    func start()
    func stop()

    /// Called after DDC probe completes to refresh volume/mute states.
    /// Default implementation is a no-op (only relevant for DDC-capable monitors).
    func refreshAfterDDCProbe()
}

extension DeviceVolumeProviding {
    func outputProcessingGain(for deviceID: AudioDeviceID) -> Float {
        1.0
    }

    func refreshOutputDeviceStates() {}

    func applyTierOverrideChange(for deviceID: AudioDeviceID) {}

    func autoDetectedOutputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        outputVolumeBackend(for: deviceID)
    }

    func refreshAfterDDCProbe() {}
}
