// FineTune/Audio/Extensions/AudioDeviceID+Info.swift
import AudioToolbox
import Foundation

// MARK: - Device Information

extension AudioDeviceID {
    func readDeviceName() throws -> String {
        try readString(kAudioObjectPropertyName)
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Float64 {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(48000))
    }

    func readTransportType() -> TransportType {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(self, &address, 0, nil, &size, &transportType)
        return TransportType(rawValue: transportType)
    }
}

// MARK: - Process Properties

extension AudioObjectID {
    func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(0))
    }

    func readProcessIsRunning() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunning)) ?? false
    }

    func readProcessBundleID() -> String? {
        try? readString(kAudioProcessPropertyBundleID)
    }
}

// MARK: - Audio Tap

extension AudioObjectID {
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}
