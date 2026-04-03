// FineTuneTests/ProcessingPipelineTests.swift
// Unit tests for the audio processing pipeline extracted from ProcessTapController.
//
// Tests ProcessTapController.processMappedBuffers() — a static, RT-safe function
// that encapsulates buffer mapping, volume ramp, channel routing, EQ chain, and
// soft limiting. Already decoupled from instance state (all deps passed as params).
//
// Coverage targets:
// 1. Buffer mapping: stereo, mono, surround, asymmetric, silence-bug regression
// 2. Volume ramp: convergence, no overshoot, zero-target, unmute, rapid changes, single-frame
// 3. Processing chain: EQ->limiter ordering, passthrough, zero-volume silence
// 4. BiquadProcessor: NaN safety, nil setup passthrough, setup swap

import AudioToolbox
import Accelerate
import Testing
@testable import FineTune

// MARK: - Test Helpers

/// Manages an AudioBufferList with Float32 data for testing.
/// Handles allocation and deallocation of both the ABL struct and data buffers.
///
/// CoreAudio's AudioBufferList is a variable-length C struct — this helper
/// handles the unsafe pointer arithmetic needed to construct one in Swift.
private final class TestABL {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private var dataPointers: [UnsafeMutablePointer<Float>] = []

    /// Create a test AudioBufferList.
    /// - Parameter buffers: Array of (channels, frameCount) describing each buffer.
    init(buffers: [(channels: UInt32, frames: Int)]) {
        let count = buffers.count
        precondition(count > 0, "Must have at least one buffer")

        // AudioBufferList: mNumberBuffers (UInt32) + mBuffers[1] inline.
        // Additional buffers need extra space beyond the inline [1].
        let extraBuffers = max(0, count - 1)
        let totalSize = MemoryLayout<AudioBufferList>.size
            + extraBuffers * MemoryLayout<AudioBuffer>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: totalSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        pointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = UInt32(count)

        let ablp = UnsafeMutableAudioBufferListPointer(pointer)
        for i in 0..<count {
            let channels = buffers[i].channels
            let frames = buffers[i].frames
            let sampleCount = Int(channels) * frames
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(sampleCount, 1))
            data.initialize(repeating: 0, count: max(sampleCount, 1))
            dataPointers.append(data)
            ablp[i] = AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
    }

    /// Access the Float data pointer for the buffer at `index`.
    func data(at index: Int) -> UnsafeMutablePointer<Float> {
        dataPointers[index]
    }

    /// The buffer list as UnsafeMutableAudioBufferListPointer (used by processMappedBuffers).
    var bufferList: UnsafeMutableAudioBufferListPointer {
        UnsafeMutableAudioBufferListPointer(pointer)
    }

    /// Total sample count for buffer at `index`.
    func sampleCount(at index: Int) -> Int {
        let buf = bufferList[index]
        return Int(buf.mDataByteSize) / MemoryLayout<Float>.size
    }

    deinit {
        for p in dataPointers { p.deallocate() }
        pointer.deallocate()
    }
}

/// Fills every sample in a TestABL buffer with a constant value.
private func fill(_ abl: TestABL, bufferIndex: Int, value: Float) {
    let data = abl.data(at: bufferIndex)
    let count = abl.sampleCount(at: bufferIndex)
    for i in 0..<count { data[i] = value }
}

/// Calls ProcessTapController.processMappedBuffers with sensible defaults.
/// `rampCoefficient: 1.0` = instant ramp (currentVol snaps to targetVol on first frame).
private func processWithDefaults(
    input: TestABL,
    output: TestABL,
    targetVol: Float = 1.0,
    crossfadeMultiplier: Float = 1.0,
    rampCoefficient: Float = 1.0,
    preferredStereoLeft: Int = 0,
    preferredStereoRight: Int = 1,
    currentVol: inout Float,
    eqProc: EQProcessor? = nil,
    autoEQProc: AutoEQProcessor? = nil
) {
    ProcessTapController.processMappedBuffers(
        inputBuffers: input.bufferList,
        outputBuffers: output.bufferList,
        targetVol: targetVol,
        crossfadeMultiplier: crossfadeMultiplier,
        rampCoefficient: rampCoefficient,
        preferredStereoLeft: preferredStereoLeft,
        preferredStereoRight: preferredStereoRight,
        currentVol: &currentVol,
        eqProc: eqProc,
        autoEQProc: autoEQProc
    )
}

// MARK: - Buffer Mapping Tests

@Suite("ProcessTapController — Buffer Mapping")
struct BufferMappingTests {

    @Test("Stereo 2ch buffer: direct 1:1 mapping preserves signal")
    func stereoDirectMapping() {
        let frames = 512
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])

        // Fill input with recognizable pattern: left=0.5, right=0.25
        let inData = input.data(at: 0)
        for f in 0..<frames {
            inData[f * 2] = 0.5
            inData[f * 2 + 1] = 0.25
        }

        var vol: Float = 1.0
        processWithDefaults(input: input, output: output, currentVol: &vol)

        let outData = output.data(at: 0)
        for f in 0..<frames {
            #expect(outData[f * 2] == 0.5, "Left channel mismatch at frame \(f)")
            #expect(outData[f * 2 + 1] == 0.25, "Right channel mismatch at frame \(f)")
        }
    }

    @Test("Mono 1ch buffer: direct 1:1 mapping preserves signal")
    func monoDirectMapping() {
        let frames = 256
        let input = TestABL(buffers: [(channels: 1, frames: frames)])
        let output = TestABL(buffers: [(channels: 1, frames: frames)])

        fill(input, bufferIndex: 0, value: 0.7)

        var vol: Float = 1.0
        processWithDefaults(input: input, output: output, currentVol: &vol)

        let outData = output.data(at: 0)
        for i in 0..<frames {
            #expect(outData[i] == 0.7, "Mono sample mismatch at \(i)")
        }
    }

    @Test("Surround 6ch buffer: direct mapping preserves all channels")
    func surroundDirectMapping() {
        let frames = 128
        let channels: UInt32 = 6
        let input = TestABL(buffers: [(channels: channels, frames: frames)])
        let output = TestABL(buffers: [(channels: channels, frames: frames)])

        let inData = input.data(at: 0)
        for f in 0..<frames {
            for ch in 0..<Int(channels) {
                inData[f * Int(channels) + ch] = Float(ch + 1) * 0.1  // 0.1, 0.2, ..., 0.6
            }
        }

        var vol: Float = 1.0
        processWithDefaults(input: input, output: output, currentVol: &vol)

        let outData = output.data(at: 0)
        for f in 0..<frames {
            for ch in 0..<Int(channels) {
                let expected = Float(ch + 1) * 0.1
                let actual = outData[f * Int(channels) + ch]
                #expect(abs(actual - expected) < 1e-6,
                        "Surround ch\(ch) frame \(f): expected \(expected), got \(actual)")
            }
        }
    }

    @Test("Asymmetric inputCount > outputCount: maps from END of input list (USB silence bug regression)")
    func asymmetricBufferOffsetMapping() {
        // USB interface scenario (e.g. FIFINE SC3): 2 input buffers, 1 output buffer.
        // Buffer 0 = HAL internal (zeros), Buffer 1 = actual audio.
        // Correct mapping: outputIndex 0 -> inputIndex (2 - 1 + 0) = 1.
        // Old bug: outputIndex 0 -> inputIndex 0 -> HAL zeros -> silence.
        let frames = 256
        let input = TestABL(buffers: [
            (channels: 2, frames: frames),  // HAL internal — zeros
            (channels: 2, frames: frames),  // Audio data — signal
        ])
        let output = TestABL(buffers: [
            (channels: 2, frames: frames),
        ])

        // HAL buffer stays zero-initialized.
        // Audio buffer gets recognizable signal.
        fill(input, bufferIndex: 1, value: 0.42)

        var vol: Float = 1.0
        processWithDefaults(input: input, output: output, currentVol: &vol)

        // Output must contain the signal, NOT HAL zeros.
        let outData = output.data(at: 0)
        #expect(outData[0] == 0.42,
                "Output should come from input buffer 1 (audio), not buffer 0 (HAL). Got \(outData[0])")
        #expect(outData[1] == 0.42)
    }

    @Test("Asymmetric 4-input 2-output: both output buffers mapped to last 2 input buffers")
    func fourInputTwoOutput() {
        let frames = 128
        let input = TestABL(buffers: [
            (channels: 2, frames: frames),  // HAL internal 0
            (channels: 2, frames: frames),  // HAL internal 1
            (channels: 2, frames: frames),  // Audio L/R pair 0
            (channels: 2, frames: frames),  // Audio L/R pair 1
        ])
        let output = TestABL(buffers: [
            (channels: 2, frames: frames),
            (channels: 2, frames: frames),
        ])

        // HAL buffers = zeros (default).
        // Audio buffers = distinct signals.
        fill(input, bufferIndex: 2, value: 0.33)
        fill(input, bufferIndex: 3, value: 0.66)

        var vol: Float = 1.0
        processWithDefaults(input: input, output: output, currentVol: &vol)

        // output[0] should come from input[2] (4-2+0=2), output[1] from input[3] (4-2+1=3)
        #expect(output.data(at: 0)[0] == 0.33,
                "Output 0 should map to input 2")
        #expect(output.data(at: 1)[0] == 0.66,
                "Output 1 should map to input 3")
    }

    @Test("inputIndex out of bounds: output zeroed safely")
    func inputIndexOutOfBounds() {
        // Edge case: more output buffers than input buffers.
        // outputIndex=1 -> inputIndex=1, but inputCount=1 -> guard fails -> memset zero.
        let frames = 64
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [
            (channels: 2, frames: frames),
            (channels: 2, frames: frames),
        ])

        fill(input, bufferIndex: 0, value: 0.5)
        // Pre-fill output[1] with garbage to verify it gets zeroed.
        fill(output, bufferIndex: 1, value: 999.0)

        var vol: Float = 1.0
        processWithDefaults(input: input, output: output, currentVol: &vol)

        // output[0] should have signal.
        #expect(output.data(at: 0)[0] == 0.5)
        // output[1] should be zeroed (no matching input).
        let outData1 = output.data(at: 1)
        for i in 0..<output.sampleCount(at: 1) {
            #expect(outData1[i] == 0.0,
                    "Out-of-bounds output buffer should be zeroed at sample \(i)")
        }
    }

    @Test("Mono input to stereo output: signal placed on preferred stereo channels")
    func monoToStereoUpmix() {
        let frames = 128
        let input = TestABL(buffers: [(channels: 1, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])

        fill(input, bufferIndex: 0, value: 0.8)

        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            preferredStereoLeft: 0, preferredStereoRight: 1,
            currentVol: &vol
        )

        let outData = output.data(at: 0)
        for f in 0..<frames {
            #expect(outData[f * 2] == 0.8, "Left channel should have mono signal at frame \(f)")
            #expect(outData[f * 2 + 1] == 0.8, "Right channel should have mono signal at frame \(f)")
        }
    }

    @Test("Stereo input to 6ch output: signal placed only on preferred stereo channels")
    func stereoToSurroundMapping() {
        let frames = 64
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 6, frames: frames)])

        let inData = input.data(at: 0)
        for f in 0..<frames {
            inData[f * 2] = 0.5      // left
            inData[f * 2 + 1] = 0.3  // right
        }

        // Route to channels 0 (left) and 1 (right) of the 6ch output.
        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            preferredStereoLeft: 0, preferredStereoRight: 1,
            currentVol: &vol
        )

        let outData = output.data(at: 0)
        for f in 0..<frames {
            let base = f * 6
            #expect(outData[base + 0] == 0.5, "Left at frame \(f)")
            #expect(outData[base + 1] == 0.3, "Right at frame \(f)")
            // Remaining channels should be zero.
            for ch in 2..<6 {
                #expect(outData[base + ch] == 0.0,
                        "Unused channel \(ch) at frame \(f) should be zero")
            }
        }
    }

    @Test("Zero-frame buffer: output zeroed, no crash")
    func zeroFrameBuffer() {
        // frameCount = 0 should hit the guard and memset output to zero.
        // Use frames=1 for allocation but set mDataByteSize=0 to simulate zero-length.
        let input = TestABL(buffers: [(channels: 2, frames: 1)])
        let output = TestABL(buffers: [(channels: 2, frames: 1)])

        // Override mDataByteSize to 0 to simulate zero-frame buffer.
        input.bufferList[0].mDataByteSize = 0
        output.bufferList[0].mDataByteSize = 0

        var vol: Float = 1.0
        // Should not crash.
        processWithDefaults(input: input, output: output, currentVol: &vol)
    }
}

// MARK: - Volume Ramp Tests

@Suite("ProcessTapController — Volume Ramp")
struct VolumeRampTests {

    @Test("Ramp converges toward target from below")
    func convergenceFromBelow() {
        let frames = 4096
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        var vol: Float = 0.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 1.0, rampCoefficient: 0.01,
            currentVol: &vol
        )

        // After 4096 frames with coeff 0.01: vol = 1 - (1-0.01)^4096 ~ 1.0
        // (0.99^4096 ~ 1.8e-18)
        #expect(vol > 0.999, "Volume should converge to target. Got \(vol)")
    }

    @Test("Ramp converges toward target from above")
    func convergenceFromAbove() {
        let frames = 4096
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 0.3, rampCoefficient: 0.01,
            currentVol: &vol
        )

        #expect(abs(vol - 0.3) < 0.001, "Volume should converge to 0.3. Got \(vol)")
    }

    @Test("Ramp never overshoots target (upward)")
    func noOvershootUpward() {
        let frames = 1024
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        let target: Float = 0.75
        var vol: Float = 0.0
        processWithDefaults(
            input: input, output: output,
            targetVol: target, rampCoefficient: 0.05,
            currentVol: &vol
        )

        // With input=1.0, crossfade=1.0, output[f] = currentVol at that frame.
        // Check every output sample is <= target.
        let outData = output.data(at: 0)
        for f in 0..<frames {
            let sample = outData[f * 2]  // left channel
            #expect(sample <= target + 1e-7,
                    "Frame \(f): output \(sample) overshoots target \(target)")
            #expect(sample >= 0.0, "Frame \(f): output should be non-negative")
        }
    }

    @Test("Ramp never overshoots target (downward)")
    func noOvershootDownward() {
        let frames = 1024
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        let target: Float = 0.25
        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            targetVol: target, rampCoefficient: 0.05,
            currentVol: &vol
        )

        let outData = output.data(at: 0)
        for f in 0..<frames {
            let sample = outData[f * 2]
            #expect(sample >= target - 1e-7,
                    "Frame \(f): output \(sample) undershoots target \(target)")
            #expect(sample <= 1.0, "Frame \(f): output should not exceed starting volume")
        }
    }

    @Test("Zero target volume: output approaches zero")
    func zeroTargetApproachesZero() {
        let frames = 8192
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 0.0, rampCoefficient: 0.01,
            currentVol: &vol
        )

        // After 8192 frames: vol = 0.99^8192 ~ 3.5e-36 — effectively zero in Float32.
        #expect(vol < 1e-6, "Volume should approach zero. Got \(vol)")

        // Last frame's output should be negligible.
        let outData = output.data(at: 0)
        let lastSample = outData[(frames - 1) * 2]
        #expect(abs(lastSample) < 1e-6, "Last sample should be near-zero")
    }

    @Test("Unmute from zero: ramp recovers to target")
    func unmuteFromZero() {
        let frames = 4096
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        var vol: Float = 0.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 0.8, rampCoefficient: 0.01,
            currentVol: &vol
        )

        #expect(vol > 0.79, "Volume should recover from zero to near target. Got \(vol)")

        // First sample should be non-zero (ramp starts immediately).
        let first = output.data(at: 0)[0]
        #expect(first > 0.0, "First output sample should be non-zero after unmute")
    }

    @Test("Rapid target reversal: ramp changes direction smoothly")
    func rapidTargetReversal() {
        let frames = 512
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        // Phase 1: ramp toward 1.0
        var vol: Float = 0.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 1.0, rampCoefficient: 0.01,
            currentVol: &vol
        )
        let volAfterUp = vol
        #expect(volAfterUp > 0.0, "Volume should have increased")

        // Phase 2: immediately reverse toward 0.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 0.0, rampCoefficient: 0.01,
            currentVol: &vol
        )
        #expect(vol < volAfterUp, "Volume should decrease after target reversal")
        #expect(vol >= 0.0, "Volume should remain non-negative")
        #expect(!vol.isNaN, "Volume should not be NaN after reversal")
    }

    @Test("Single-frame buffer: ramp applies exactly once")
    func singleFrameBuffer() {
        let input = TestABL(buffers: [(channels: 2, frames: 1)])
        let output = TestABL(buffers: [(channels: 2, frames: 1)])
        fill(input, bufferIndex: 0, value: 1.0)

        var vol: Float = 0.0
        let coeff: Float = 0.1
        processWithDefaults(
            input: input, output: output,
            targetVol: 1.0, rampCoefficient: coeff,
            currentVol: &vol
        )

        // After 1 frame: vol = 0 + (1.0 - 0) * 0.1 = 0.1
        let expected: Float = 0.1
        #expect(abs(vol - expected) < 1e-7,
                "After one frame, vol should be \(expected). Got \(vol)")
    }

    @Test("Ramp is symmetric: same coefficient, same speed up and down")
    func rampSymmetry() {
        let frames = 256
        let coeff: Float = 0.02

        // Ramp UP from 0.0 -> 1.0
        let inputUp = TestABL(buffers: [(channels: 2, frames: frames)])
        let outputUp = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(inputUp, bufferIndex: 0, value: 1.0)

        var volUp: Float = 0.0
        processWithDefaults(
            input: inputUp, output: outputUp,
            targetVol: 1.0, rampCoefficient: coeff,
            currentVol: &volUp
        )
        let distanceUp = 1.0 - volUp  // How far from target after N frames

        // Ramp DOWN from 1.0 -> 0.0
        let inputDn = TestABL(buffers: [(channels: 2, frames: frames)])
        let outputDn = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(inputDn, bufferIndex: 0, value: 1.0)

        var volDn: Float = 1.0
        processWithDefaults(
            input: inputDn, output: outputDn,
            targetVol: 0.0, rampCoefficient: coeff,
            currentVol: &volDn
        )
        let distanceDn = volDn  // How far from target (0.0) after N frames

        // Both should have traveled the same fractional distance.
        // After N frames: distance = (1-coeff)^N. Both start 1.0 away from target.
        #expect(abs(distanceUp - distanceDn) < 1e-5,
                "Ramp should be symmetric: up distance=\(distanceUp), down distance=\(distanceDn)")
    }

    @Test("Crossfade multiplier scales output correctly")
    func crossfadeMultiplierEffect() {
        let frames = 64
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 1.0)

        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 1.0, crossfadeMultiplier: 0.5,
            currentVol: &vol
        )

        // gain = currentVol(1.0) * crossfadeMultiplier(0.5) = 0.5
        let outData = output.data(at: 0)
        for f in 0..<frames {
            #expect(abs(outData[f * 2] - 0.5) < 1e-7,
                    "Crossfade multiplier should halve output at frame \(f)")
        }
    }

    @Test("Volume above unity: boost up to 4x (12dB)")
    func volumeBoost() {
        let frames = 64
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 0.2)

        var vol: Float = 4.0  // Maximum boost
        processWithDefaults(
            input: input, output: output,
            targetVol: 4.0,
            currentVol: &vol
        )

        // Output = 0.2 * 4.0 = 0.8 (before limiter, which won't engage at 0.8)
        let outData = output.data(at: 0)
        #expect(abs(outData[0] - 0.8) < 1e-6, "4x boost on 0.2 input should give 0.8")
    }
}

// MARK: - Processing Chain Tests

@Suite("ProcessTapController — Processing Chain")
struct ProcessingChainTests {

    @Test("Flat EQ + unity volume = near-passthrough")
    func flatEQPassthrough() {
        let frames = 2048
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])

        // Fill with a recognizable pattern.
        let inData = input.data(at: 0)
        for i in 0..<(frames * 2) {
            inData[i] = 0.3 * Float(sin(Double(i) * 0.1))
        }

        let eq = EQProcessor(sampleRate: 48000)
        // EQProcessor init already applies EQSettings.flat.

        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            currentVol: &vol, eqProc: eq
        )

        // Flat EQ should produce output ~ input within Float32 tolerance.
        // 10 cascaded biquad sections at 0dB still introduce ~1e-4 error (L-043).
        let outData = output.data(at: 0)
        var maxError: Float = 0
        for i in 0..<(frames * 2) {
            let error = abs(outData[i] - inData[i])
            maxError = max(maxError, error)
        }
        #expect(maxError < 1e-3,
                "Flat EQ should be near-passthrough. Max error: \(maxError)")
    }

    @Test("EQ applied before SoftLimiter: boosted peaks are caught")
    func eqBeforeLimiter() {
        // Strategy: boost EQ so output exceeds 1.0 before limiting.
        // If EQ runs after limiter, peaks would slip through.
        // If EQ runs before limiter (correct), output <= 1.0.
        let frames = 4096
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])

        // Input at 0.5 amplitude — will exceed 1.0 after EQ boost.
        let inData = input.data(at: 0)
        let freq = 1000.0  // 1kHz — center of EQ band 4
        let sampleRate = 48000.0
        let omega = 2.0 * Double.pi * freq / sampleRate
        for f in 0..<frames {
            let sample = Float(0.5 * sin(omega * Double(f)))
            inData[f * 2] = sample
            inData[f * 2 + 1] = sample
        }

        // Create EQ with +12dB boost at 1kHz (band 4).
        let eq = EQProcessor(sampleRate: sampleRate)
        var gains = [Float](repeating: 0, count: 10)
        gains[4] = 12.0  // +12dB at 1kHz
        let settings = EQSettings(bandGains: gains, isEnabled: true)
        eq.updateSettings(settings)

        var vol: Float = 1.0
        processWithDefaults(
            input: input, output: output,
            currentVol: &vol, eqProc: eq
        )

        // After EQ boost + SoftLimiter: output should never exceed +/-1.0.
        let outData = output.data(at: 0)
        var maxAbs: Float = 0
        for i in 0..<(frames * 2) {
            maxAbs = max(maxAbs, abs(outData[i]))
        }
        #expect(maxAbs <= SoftLimiter.ceiling,
                "SoftLimiter should catch EQ-boosted peaks. Max: \(maxAbs)")
        // Also verify EQ actually boosted (output peak > input peak).
        #expect(maxAbs > 0.5,
                "EQ boost should increase output above input level. Max: \(maxAbs)")
    }

    @Test("Zero volume produces all-zero output")
    func zeroVolumeProducesZeros() {
        let frames = 256
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 0.9)

        var vol: Float = 0.0
        processWithDefaults(
            input: input, output: output,
            targetVol: 0.0,
            currentVol: &vol
        )

        let outData = output.data(at: 0)
        for i in 0..<(frames * 2) {
            #expect(outData[i] == 0.0,
                    "Zero volume should produce zero output at sample \(i)")
        }
    }

    @Test("SoftLimiter engages on boosted volume without EQ")
    func limiterEngagesOnBoost() {
        let frames = 256
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])
        fill(input, bufferIndex: 0, value: 0.5)

        var vol: Float = 3.0  // 3x boost -> 0.5 * 3.0 = 1.5, exceeds threshold
        processWithDefaults(
            input: input, output: output,
            targetVol: 3.0,
            currentVol: &vol
        )

        let outData = output.data(at: 0)
        for i in 0..<(frames * 2) {
            #expect(outData[i] <= SoftLimiter.ceiling,
                    "Limiter should constrain boosted output. Sample \(i): \(outData[i])")
            #expect(outData[i] > SoftLimiter.threshold,
                    "Output should be above threshold (limiter compresses, not clips). Sample \(i): \(outData[i])")
        }
    }

    @Test("EQ disabled: output equals volume-scaled input (no filter artifacts)")
    func eqDisabledPassthrough() {
        let frames = 512
        let input = TestABL(buffers: [(channels: 2, frames: frames)])
        let output = TestABL(buffers: [(channels: 2, frames: frames)])

        let inData = input.data(at: 0)
        for i in 0..<(frames * 2) { inData[i] = 0.4 }

        let eq = EQProcessor(sampleRate: 48000)
        let disabledSettings = EQSettings(bandGains: EQSettings.flat.bandGains, isEnabled: false)
        eq.updateSettings(disabledSettings)

        var vol: Float = 0.8
        processWithDefaults(
            input: input, output: output,
            targetVol: 0.8,
            currentVol: &vol, eqProc: eq
        )

        // Output should be 0.4 * 0.8 = 0.32 exactly (no filter processing).
        let outData = output.data(at: 0)
        for f in 0..<frames {
            #expect(abs(outData[f * 2] - 0.32) < 1e-6,
                    "EQ disabled should produce clean gain-only output at frame \(f)")
        }
    }

    @Test("Trailing output samples beyond frameCount are zeroed")
    func trailingSamplesZeroed() {
        // When outputSampleCount > frameCount * outputChannels, the remainder is zeroed.
        // This happens when output buffer is larger than what we process.
        // We can test this with inputFrames < outputFrames.
        let inputFrames = 64
        let outputFrames = 128
        let input = TestABL(buffers: [(channels: 2, frames: inputFrames)])
        let output = TestABL(buffers: [(channels: 2, frames: outputFrames)])

        fill(input, bufferIndex: 0, value: 0.5)
        fill(output, bufferIndex: 0, value: 999.0)  // Pre-fill with garbage

        var vol: Float = 1.0
        processWithDefaults(input: input, output: output, currentVol: &vol)

        let outData = output.data(at: 0)
        // First inputFrames frames should have signal.
        #expect(outData[0] == 0.5)
        // Trailing frames should be zeroed.
        let trailingStart = inputFrames * 2
        for i in trailingStart..<(outputFrames * 2) {
            #expect(outData[i] == 0.0,
                    "Trailing sample \(i) should be zeroed, got \(outData[i])")
        }
    }
}

// MARK: - BiquadProcessor Tests

@Suite("BiquadProcessor — Safety and Bypass")
struct BiquadProcessorSafetyTests {

    @Test("nil setup = passthrough (output matches input)")
    func nilSetupPassthrough() {
        let processor = BiquadProcessor(
            sampleRate: 48000, maxSections: 10,
            category: "test", initiallyEnabled: true
        )
        // No setup loaded — _eqSetup is nil.

        let frames = 256
        let sampleCount = frames * 2
        let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input.deallocate(); output.deallocate() }

        for i in 0..<sampleCount { input[i] = Float(i) * 0.001 }
        memset(output, 0, sampleCount * MemoryLayout<Float>.size)

        processor.process(input: input, output: output, frameCount: frames)

        for i in 0..<sampleCount {
            #expect(output[i] == input[i],
                    "nil setup should copy input to output at sample \(i)")
        }
    }

    @Test("Disabled processor = passthrough regardless of setup")
    func disabledPassthrough() {
        let processor = BiquadProcessor(
            sampleRate: 48000, maxSections: 10,
            category: "test", initiallyEnabled: false
        )
        // Load a real setup but keep disabled.
        let gains = [Float](repeating: 6.0, count: 10)  // +6dB all bands
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(10))
        }
        processor.swapSetup(setup)
        // Keep disabled.

        let frames = 256
        let sampleCount = frames * 2
        let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input.deallocate(); output.deallocate() }

        for i in 0..<sampleCount { input[i] = 0.3 }
        memset(output, 0, sampleCount * MemoryLayout<Float>.size)

        processor.process(input: input, output: output, frameCount: frames)

        for i in 0..<sampleCount {
            #expect(output[i] == input[i],
                    "Disabled processor should copy input to output at sample \(i)")
        }
    }

    @Test("NaN input triggers safety net: output zeroed, delay buffers reset")
    func nanInputSafetyNet() {
        // Create a processor with a real setup so it processes (not bypasses).
        let processor = BiquadProcessor(
            sampleRate: 48000, maxSections: 10,
            category: "test", initiallyEnabled: true
        )
        let gains = [Float](repeating: 0.0, count: 10)  // Flat EQ
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(10))
        }
        processor.swapSetup(setup)
        processor.setEnabled(true)

        let frames = 256
        let sampleCount = frames * 2
        let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input.deallocate(); output.deallocate() }

        // Fill input with NaN.
        for i in 0..<sampleCount { input[i] = Float.nan }

        processor.process(input: input, output: output, frameCount: frames)

        // Safety net: output should be zeroed.
        for i in 0..<sampleCount {
            #expect(output[i] == 0.0,
                    "NaN input should produce zeroed output at sample \(i)")
        }

        // Verify recovery: process normal audio after NaN.
        for i in 0..<sampleCount { input[i] = 0.5 }
        processor.process(input: input, output: output, frameCount: frames)

        // Output should be non-NaN (delay buffers were reset).
        for i in 0..<sampleCount {
            #expect(!output[i].isNaN,
                    "After NaN recovery, output should not be NaN at sample \(i)")
        }
    }

    @Test("In-place processing: input == output pointer works correctly")
    func inPlaceProcessing() {
        let processor = BiquadProcessor(
            sampleRate: 48000, maxSections: 10,
            category: "test", initiallyEnabled: true
        )
        let gains = [Float](repeating: 0.0, count: 10)
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(10))
        }
        processor.swapSetup(setup)
        processor.setEnabled(true)

        let frames = 512
        let sampleCount = frames * 2
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { buffer.deallocate() }

        for i in 0..<sampleCount { buffer[i] = 0.4 }

        // Process in-place (input == output).
        processor.process(input: buffer, output: buffer, frameCount: frames)

        // Flat EQ in-place should produce ~ same signal.
        for i in 0..<sampleCount {
            #expect(!buffer[i].isNaN, "In-place result should not be NaN at \(i)")
            #expect(abs(buffer[i] - 0.4) < 1e-3,
                    "Flat EQ in-place should preserve signal at \(i). Got \(buffer[i])")
        }
    }

    @Test("Setup swap to nil: transitions cleanly to bypass")
    func setupSwapToNil() {
        let processor = BiquadProcessor(
            sampleRate: 48000, maxSections: 10,
            category: "test", initiallyEnabled: true
        )
        let gains = [Float](repeating: 3.0, count: 10)
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(10))
        }
        processor.swapSetup(setup)
        processor.setEnabled(true)

        // Now swap to nil.
        processor.swapSetup(nil)

        let frames = 256
        let sampleCount = frames * 2
        let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input.deallocate(); output.deallocate() }

        for i in 0..<sampleCount { input[i] = 0.6 }

        processor.process(input: input, output: output, frameCount: frames)

        // With nil setup, should bypass (copy input to output).
        for i in 0..<sampleCount {
            #expect(output[i] == input[i],
                    "After swap to nil, should bypass at sample \(i)")
        }
    }
}
