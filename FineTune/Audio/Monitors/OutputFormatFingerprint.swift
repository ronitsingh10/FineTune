import AudioToolbox

/// Snapshot of output sample rate plus physical stream format. Detects bit-depth changes that
/// `kAudioDevicePropertyNominalSampleRate` listeners miss.
struct OutputFormatFingerprint: Equatable, Sendable {
    let sampleRate: Double
    let formatID: UInt32
    let bitsPerChannel: UInt32

    static func from(deviceID: AudioDeviceID) -> OutputFormatFingerprint? {
        let rate = (try? deviceID.readNominalSampleRate()) ?? 0
        guard rate > 0 else { return nil }

        if let asbd = deviceID.readPhysicalFormat() {
            return OutputFormatFingerprint(
                sampleRate: rate,
                formatID: asbd.mFormatID,
                bitsPerChannel: asbd.mBitsPerChannel
            )
        }
        return OutputFormatFingerprint(sampleRate: rate, formatID: 0, bitsPerChannel: 0)
    }

    static func isMeaningfulChange(old: OutputFormatFingerprint?, new: OutputFormatFingerprint?) -> Bool {
        guard let new, new.sampleRate > 0 else { return false }
        guard let old else { return true }
        return old != new
    }
}
