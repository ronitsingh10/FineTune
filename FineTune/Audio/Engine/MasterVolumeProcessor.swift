// Adapted from wait2050/FineTune-Sync (GPLv3), commit be9919920e04.
// https://github.com/wait2050/FineTune-Sync/commit/be9919920e0406fc6eafff7b598af0e1650bccf5
// Modified 2026-11-16 to keep ramp state with each IOProc and settle at both endpoints.
import AudioToolbox
import Synchronization

/// A separately seeded ramp for each IOProc, retained by its callback through promotion.
nonisolated final class MasterVolumeRamp: Sendable {
    private let gainBits: Atomic<UInt32>
    private let coefficient: Float

    init(gain: Float, coefficient: Float) {
        gainBits = Atomic(gain.bitPattern)
        self.coefficient = coefficient
    }

    /// Main actor reads this snapshot to seed a new crossfade destination.
    var currentGain: Float { Float(bitPattern: gainBits.load(ordering: .relaxed)) }

    /// Only the IOProc that owns this ramp may advance it.
    func apply(to buffers: UnsafeMutableAudioBufferListPointer, targetGain: Float) {
        let current = currentGain
        let next = MasterVolumeProcessor.process(
            buffers, targetGain: targetGain, currentGain: current, rampCoefficient: coefficient
        )
        if next != current {
            gainBits.store(next.bitPattern, ordering: .relaxed)
        }
    }
}

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
            if targetGain == 0 && currentGain == 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
                continue
            }
            var gain = currentGain
            for frame in 0..<frames {
                gain += (targetGain - gain) * rampCoefficient
                if abs(targetGain - gain) < 0.0001 { gain = targetGain }
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
