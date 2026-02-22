// FineTune/Audio/Extensions/AudioObjectID+System.swift
import AudioToolbox
import Foundation

// MARK: - Device List

extension AudioObjectID {
    static func readDeviceList() throws -> [AudioDeviceID] {
        try AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices,
            defaultValue: AudioDeviceID.unknown
        )
    }

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList,
            defaultValue: AudioObjectID.unknown
        )
    }
}

// MARK: - Default Device

extension AudioDeviceID {
    /// Reads the main audio output device (what user selects in Sound preferences)
    /// NOTE: Use DeviceVolumeMonitor.defaultDeviceUID when available, as it's cached and listener-updated
    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice,  // Main audio output, NOT system alert sounds
            defaultValue: AudioDeviceID.unknown
        )
    }

    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceIDValue = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &deviceIDValue
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
    }
}

// MARK: - System Output Device (for alerts and system sounds)

extension AudioDeviceID {
    /// Reads the system output device (for alerts, notifications, and system sounds)
    /// This is separate from the default output device used by apps
    static func readSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    /// Sets the system output device (for alerts, notifications, and system sounds)
    static func setSystemOutputDevice(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceIDValue = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &deviceIDValue
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
    }
}

// MARK: - Default Input Device

extension AudioDeviceID {
    /// Reads the main audio input device (microphone selected in Sound preferences)
    /// NOTE: Use DeviceVolumeMonitor.defaultInputDeviceUID when available, as it's cached and listener-updated
    static func readDefaultInputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    /// Sets the default input device (microphone)
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceIDValue = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &deviceIDValue
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
    }
}
