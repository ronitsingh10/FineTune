// FineTune/Audio/Extensions/AudioDeviceID+Volume.swift
import AudioToolbox

// MARK: - Volume Control Detection

extension AudioDeviceID {
    /// Returns true if this device supports CoreAudio volume control.
    /// Monitors connected via HDMI/DisplayPort often return false here.
    func hasOutputVolumeControl() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }
}

// MARK: - Device Volume

extension AudioDeviceID {
    /// Reads the scalar volume (0.0 to 1.0) for the device.
    /// Tries multiple strategies to find the most representative volume:
    /// 1. Virtual main volume via VirtualMainVolume (matches system volume slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    func readOutputVolumeScalar() -> Float {
        // Strategy 1: Try virtual main volume (preferred - matches system slider)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
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

        // Strategy 2: Try master volume scalar (element 0)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
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
    /// Uses VirtualMainVolume via VirtualMainVolume to match system volume slider behavior.
    /// Returns true if successful, false otherwise.
    func setOutputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &volumeValue)
        return err == noErr
    }
}

// MARK: - Device Balance

extension AudioDeviceID {
    /// Returns true if this device supports stereo balance control via VirtualMainBalance
    /// or settable left/right channel VolumeScalar elements.
    func supportsOutputBalance() -> Bool {
        if hasVirtualMainBalance() { return true }
        return hasSettableStereoChannelVolumes()
    }

    /// Reads stereo balance (0.0 = full left, 0.5 = center, 1.0 = full right).
    /// Prefers VirtualMainBalance; falls back to L/R channel VolumeScalar ratio.
    func readOutputBalance() -> Float {
        if let balance = readVirtualMainBalance() {
            return StereoBalance.clamp(balance)
        }
        if let balance = readBalanceFromChannelVolumes() {
            return StereoBalance.clamp(balance)
        }
        return StereoBalance.center
    }

    /// Sets stereo balance (0.0 = full left, 0.5 = center, 1.0 = full right).
    /// Prefers VirtualMainBalance; falls back to L/R channel VolumeScalar writes
    /// that preserve the louder channel's current volume as the master level.
    @discardableResult
    func setOutputBalance(_ balance: Float) -> Bool {
        let clamped = StereoBalance.clamp(balance)
        if hasVirtualMainBalance() {
            return setVirtualMainBalance(clamped)
        }
        return setBalanceViaChannelVolumes(clamped)
    }

    // MARK: VirtualMainBalance

    private func virtualMainBalanceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func hasVirtualMainBalance() -> Bool {
        var address = virtualMainBalanceAddress()
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }

    private func readVirtualMainBalance() -> Float? {
        var address = virtualMainBalanceAddress()
        guard AudioObjectHasProperty(self, &address) else { return nil }
        var balance: Float32 = StereoBalance.center
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &balance)
        guard err == noErr else { return nil }
        return balance
    }

    private func setVirtualMainBalance(_ balance: Float) -> Bool {
        var address = virtualMainBalanceAddress()
        guard AudioObjectHasProperty(self, &address) else { return false }
        var value: Float32 = balance
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        return err == noErr
    }

    // MARK: Channel-volume fallback

    private func hasSettableStereoChannelVolumes() -> Bool {
        let stereo = preferredStereoChannelIndices()
        // CoreAudio elements are 1-based; preferredStereoChannelIndices returns 0-based.
        let leftElement = UInt32(stereo.left + 1)
        let rightElement = UInt32(stereo.right + 1)
        return isVolumeScalarSettable(element: leftElement)
            && isVolumeScalarSettable(element: rightElement)
    }

    private func isVolumeScalarSettable(element: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }

    private func readChannelVolumeScalar(element: UInt32) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(self, &address) else { return nil }
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
        guard err == noErr else { return nil }
        return volume
    }

    private func setChannelVolumeScalar(element: UInt32, volume: Float) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(self, &address) else { return false }
        var value: Float32 = Swift.max(0.0, Swift.min(1.0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        return err == noErr
    }

    /// Derives balance from L/R channel scalars: louder side = 1.0 relative,
    /// quieter side scaled. Equal volumes → center.
    private func readBalanceFromChannelVolumes() -> Float? {
        let stereo = preferredStereoChannelIndices()
        let leftElement = UInt32(stereo.left + 1)
        let rightElement = UInt32(stereo.right + 1)
        guard let left = readChannelVolumeScalar(element: leftElement),
              let right = readChannelVolumeScalar(element: rightElement) else {
            return nil
        }
        return StereoBalance.fromChannelVolumes(left: left, right: right)
    }

    /// Writes L/R channel volumes from balance while preserving the current max channel level.
    private func setBalanceViaChannelVolumes(_ balance: Float) -> Bool {
        let stereo = preferredStereoChannelIndices()
        let leftElement = UInt32(stereo.left + 1)
        let rightElement = UInt32(stereo.right + 1)
        let currentLeft = readChannelVolumeScalar(element: leftElement) ?? 1.0
        let currentRight = readChannelVolumeScalar(element: rightElement) ?? 1.0
        let master = Swift.max(currentLeft, currentRight)
        let gains = StereoBalance.channelGains(for: balance)
        let leftOK = setChannelVolumeScalar(element: leftElement, volume: master * gains.left)
        let rightOK = setChannelVolumeScalar(element: rightElement, volume: master * gains.right)
        return leftOK && rightOK
    }
}

// MARK: - Device Mute

extension AudioDeviceID {
    /// Reads the mute state for the device.
    /// Returns true if muted, false if unmuted or if mute is not supported.
    func readMuteState() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
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
            mScope: kAudioObjectPropertyScopeOutput,
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
    /// 1. Virtual main volume via VirtualMainVolume (matches system input slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    func readInputVolumeScalar() -> Float {
        // Strategy 1: Try virtual main volume (preferred - matches system slider)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeInput,
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

        // Strategy 2: Try master volume scalar (element 0)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
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
    /// Uses VirtualMainVolume via VirtualMainVolume to match system input slider behavior.
    /// Returns true if successful, false otherwise.
    func setInputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &volumeValue)
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
            mScope: kAudioObjectPropertyScopeInput,
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
            mScope: kAudioObjectPropertyScopeInput,
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
