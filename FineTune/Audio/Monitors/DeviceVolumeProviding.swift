import AudioToolbox

enum VolumeControlTier: Equatable {
    case hardware
    case ddc
    case software
}

@MainActor
protocol DeviceVolumeProviding: AnyObject {
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

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier
    func outputProcessingGain(for deviceID: AudioDeviceID) -> Float
    func refreshOutputDeviceStates()

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

    func refreshAfterDDCProbe() {}
}
