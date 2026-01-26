// FineTune/Audio/Extensions/AudioObjectID+System.swift
import AudioToolbox
import Foundation

// MARK: - Device List

extension AudioObjectID {
    static func readDeviceList() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return deviceIDs
    }

    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return objectIDs
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

    /// Reads the UID of the main audio output device
    /// NOTE: Use DeviceVolumeMonitor.defaultDeviceUID when available
    static func readDefaultOutputDeviceUID() throws -> String {
        let deviceID = try readDefaultOutputDevice()
        return try deviceID.readDeviceUID()
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
