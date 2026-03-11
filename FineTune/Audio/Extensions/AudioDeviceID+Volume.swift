// FineTune/Audio/Extensions/AudioDeviceID+Volume.swift
import AudioToolbox

// MARK: - Volume Control Detection

extension AudioDeviceID {
    /// Returns true if this device supports CoreAudio volume control.
    /// Monitors connected via HDMI/DisplayPort often return false here.
    func hasOutputVolumeControl() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioHardwareServiceHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        let err = AudioHardwareServiceIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }
}

// MARK: - Device Volume

extension AudioDeviceID {
    /// Reads the scalar volume (0.0 to 1.0) for the device.
    /// Tries multiple strategies to find the most representative volume:
    /// 1. Virtual main volume via AudioHardwareService (matches system volume slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    func readOutputVolumeScalar() -> Float {
        // Strategy 1: Try virtual main volume (preferred - matches system slider)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioHardwareServiceHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioHardwareServiceGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 2: Try master volume scalar (element 0)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 3: Try left channel (element 1) - common for stereo devices
        address.mElement = 1
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // No volume control available
        return 1.0
    }

    /// Sets the scalar volume (0.0 to 1.0) for the device.
    /// Uses VirtualMainVolume via AudioHardwareService to match system volume slider behavior.
    /// Returns true if successful, false otherwise.
    func setOutputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioHardwareServiceHasProperty(self, &address) else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioHardwareServiceSetPropertyData(self, &address, 0, nil, size, &volumeValue)
        return err == noErr
    }
}

// MARK: - Device Mute

extension AudioDeviceID {
    /// Reads the mute state for the device.
    /// Returns true if muted, false if unmuted or if mute is not supported.
    func readMuteState() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &muted)
        return err == noErr && muted != 0
    }

    /// Sets the mute state for the device.
    /// Returns true if successful, false otherwise.
    func setMuteState(_ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        return err == noErr
    }
}

// MARK: - Input Device Volume

extension AudioDeviceID {
    /// Reads the scalar volume (0.0 to 1.0) for the input device (microphone).
    /// Tries multiple strategies to find the most representative volume:
    /// 1. Virtual main volume via AudioHardwareService (matches system input slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    func readInputVolumeScalar() -> Float {
        // Strategy 1: Try virtual main volume (preferred - matches system slider)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioHardwareServiceHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioHardwareServiceGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 2: Try master volume scalar (element 0)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 3: Try left channel (element 1) - common for stereo devices
        address.mElement = 1
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // No volume control available
        return 1.0
    }

    /// Sets the scalar volume (0.0 to 1.0) for the input device (microphone).
    /// Uses VirtualMainVolume via AudioHardwareService to match system input slider behavior.
    /// Returns true if successful, false otherwise.
    func setInputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioHardwareServiceHasProperty(self, &address) else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioHardwareServiceSetPropertyData(self, &address, 0, nil, size, &volumeValue)
        return err == noErr
    }
}

// MARK: - Input Device Mute

extension AudioDeviceID {
    /// Reads the mute state for the input device (microphone).
    /// Returns true if muted, false if unmuted or if mute is not supported.
    func readInputMuteState() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &muted)
        return err == noErr && muted != 0
    }

    /// Sets the mute state for the input device (microphone).
    /// Returns true if successful, false otherwise.
    func setInputMuteState(_ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        return err == noErr
    }
}
