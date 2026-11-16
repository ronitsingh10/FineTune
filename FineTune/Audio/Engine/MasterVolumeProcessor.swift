// Based on the GPLv3 master-volume implementation in wait2050/FineTune-Sync.
// https://github.com/wait2050/FineTune-Sync
import AudioToolbox

/// Real-time-safe final attenuation for all FineTune-managed output streams.
/// Planar buffers share the same starting gain and end-of-buffer ramp state.
enum MasterVolumeProcessor {
    nonisolated static func process(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        targetGain: Float,
        currentGain: Float,
        rampCoefficient: Float
    ) -> Float {
        if targetGain == 1 && currentGain == 1 { return 1 }
        var finalGain = currentGain
        var longestBuffer = 0
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            var gain = currentGain
            for frame in 0..<frames {
                gain += (targetGain - gain) * rampCoefficient
                if targetGain == 0 && gain < 0.000001 { gain = 0 }
                for channel in 0..<channels {
                    samples[frame * channels + channel] *= gain
                }
            }
            if frames > longestBuffer {
                longestBuffer = frames
                finalGain = gain
            }
        }
        return finalGain
    }
}
