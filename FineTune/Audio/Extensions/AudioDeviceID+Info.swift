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

    func readAvailableNominalSampleRates() throws -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard sizeErr == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(sizeErr))
        }

        guard size >= UInt32(MemoryLayout<AudioValueRange>.size) else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: count
        )

        var mutableSize = size
        let dataErr = AudioObjectGetPropertyData(self, &address, 0, nil, &mutableSize, &ranges)
        guard dataErr == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(dataErr))
        }

        return Self.normalizedNominalSampleRates(from: ranges)
    }

    func canSetNominalSampleRate() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &isSettable)
        return err == noErr && isSettable.boolValue
    }

    func setNominalSampleRate(_ rate: Double) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newRate = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &newRate)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
    }

    func readTransportType() -> TransportType {
        let raw = (try? read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
        return TransportType(rawValue: raw)
    }

    private static func normalizedNominalSampleRates(from ranges: [AudioValueRange]) -> [Double] {
        let commonRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000]
        var collected = Set<Int>()

        for range in ranges {
            let minRate = range.mMinimum
            let maxRate = range.mMaximum
            if minRate <= 0 || maxRate <= 0 { continue }

            if abs(maxRate - minRate) < 1 {
                collected.insert(Int(minRate.rounded()))
                continue
            }

            for rate in commonRates where rate >= minRate && rate <= maxRate {
                collected.insert(Int(rate.rounded()))
            }
        }

        return collected
            .map(Double.init)
            .sorted()
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
