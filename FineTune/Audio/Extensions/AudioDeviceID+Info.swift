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
        let raw = (try? read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
        return TransportType(rawValue: raw)
    }
}

// MARK: - Tap Properties

extension AudioObjectID {
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
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
