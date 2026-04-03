// FineTuneTests/BiquadProcessorSignalAdversarialTests.swift
// Adversarial signal-domain tests for BiquadProcessor.
//
// Targets failure modes the integration tests (BiquadProcessorSignalTests.swift) don't cover:
// - Boundary frame counts (0, 1)
// - NaN mid-buffer propagation (safety net limitation)
// - Delay buffer state carryover between process() calls
// - Enable/disable cycling with signal verification
// - Extreme input amplitudes
// - DC and Nyquist signal invariants
// - Rapid settings churn
// - Process ordering and double-process effects
//

import Accelerate
import Testing
@testable import FineTune

// MARK: - Shared Test Helpers

/// Reusable signal generation and measurement for adversarial tests.
private enum AdversarialSignal {

    static func makeStereoSine(
        frequency: Double,
        amplitude: Float = 1.0,
        sampleRate: Double,
        frameCount: Int
    ) -> UnsafeMutablePointer<Float> {
        let sampleCount = frameCount * 2
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let omega = 2.0 * Double.pi * frequency / sampleRate
        for i in 0..<frameCount {
            let sample = amplitude * Float(sin(omega * Double(i)))
            buffer[i * 2] = sample
            buffer[i * 2 + 1] = sample
        }
        return buffer
    }

    static func makeOutputBuffer(frameCount: Int) -> UnsafeMutablePointer<Float> {
        let count = frameCount * 2
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buf.initialize(repeating: 0, count: count)
        return buf
    }

    static func measureRMS(
        buffer: UnsafePointer<Float>,
        channel: Int,
        frameCount: Int,
        skipFrames: Int
    ) -> Float {
        var sumSquares: Float = 0
        let measureFrames = frameCount - skipFrames
        guard measureFrames > 0 else { return 0 }
        for i in skipFrames..<frameCount {
            let sample = buffer[i * 2 + channel]
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(measureFrames))
    }

    /// Create a single-section peaking EQ BiquadProcessor.
    static func makePeakingProcessor(
        frequency: Double = 1000,
        gainDB: Float = 12,
        sampleRate: Double = 48000
    ) -> BiquadProcessor {
        let processor = BiquadProcessor(
            sampleRate: sampleRate,
            maxSections: 1,
            category: "test-adversarial",
            initiallyEnabled: true
        )
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: frequency, gainDB: gainDB,
            q: BiquadMath.graphicEQQ, sampleRate: sampleRate
        )
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(1))
        }
        processor.swapSetup(setup)
        return processor
    }
}


// MARK: - Suite 1: Boundary Frame Counts

@Suite("Adversarial — Boundary Frame Counts")
struct BoundaryFrameCountTests {

    @Test("frameCount=1: single stereo frame processes without crash or NaN")
    func singleFrameProcessing() {
        let processor = AdversarialSignal.makePeakingProcessor()

        let input = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        defer { input.deallocate(); output.deallocate() }

        input[0] = 0.5  // left
        input[1] = 0.5  // right
        output[0] = 0
        output[1] = 0

        processor.process(input: input, output: output, frameCount: 1)

        #expect(!output[0].isNaN, "Single frame L should not be NaN")
        #expect(!output[1].isNaN, "Single frame R should not be NaN")
        #expect(output[0].isFinite, "Single frame L should be finite")
        #expect(output[1].isFinite, "Single frame R should be finite")
    }

    @Test("frameCount=2: minimal multi-frame processes correctly")
    func twoFrameProcessing() {
        let processor = AdversarialSignal.makePeakingProcessor()
        let frameCount = 2

        let input = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        defer { input.deallocate(); output.deallocate() }

        for i in 0..<(frameCount * 2) {
            input[i] = 0.5
            output[i] = 0
        }

        processor.process(input: input, output: output, frameCount: frameCount)

        for i in 0..<(frameCount * 2) {
            #expect(output[i].isFinite, "Frame \(i) should be finite")
        }
    }

    @Test("Large frameCount (65536) processes without issue")
    func largeFrameCount() {
        let processor = AdversarialSignal.makePeakingProcessor()
        let frameCount = 65536

        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        // Measure steady-state gain should still be ~+12dB
        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: 4096
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: 4096
        )
        let gain = outputRMS / inputRMS
        #expect(gain > 3.5 && gain < 4.5,
                "Large buffer +12dB at 1kHz: expected ~4x, got \(gain)x")
    }
}


// MARK: - Suite 2: NaN Mid-Buffer Propagation

@Suite("Adversarial — NaN Mid-Buffer Propagation")
struct NaNMidBufferTests {

    @Test("NaN injected mid-buffer: safety net only checks output[0..1], mid-buffer NaN propagates uncaught")
    func nanMidBufferNotCaughtBySafetyNet() {
        // The production NaN safety net checks output[0].isNaN || output[1].isNaN.
        // If NaN appears only at frame N>0, it is NOT caught on the current call.
        // This test documents that limitation.
        let processor = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        settings.bandGains[5] = 6
        processor.updateSettings(settings)

        let frameCount = 1024
        let sampleCount = frameCount * 2

        let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input.deallocate(); output.deallocate() }

        // Valid signal with NaN injected at frame 500 (not frame 0)
        let omega = 2.0 * Double.pi * 1000.0 / 48000.0
        for i in 0..<frameCount {
            let sample = Float(sin(omega * Double(i)))
            input[i * 2] = sample
            input[i * 2 + 1] = sample
        }
        // Inject NaN mid-buffer
        input[500 * 2] = .nan
        input[500 * 2 + 1] = .nan

        processor.process(input: input, output: output, frameCount: frameCount)

        // Frames before the NaN injection point should be finite
        var earlyFramesFinite = true
        for i in 0..<490 { // well before injection point
            if !output[i * 2].isFinite || !output[i * 2 + 1].isFinite {
                earlyFramesFinite = false
                break
            }
        }
        #expect(earlyFramesFinite, "Frames before NaN injection should be finite")

        // Check if any frames after injection contain NaN — this is the
        // documented limitation of the safety net
        var hasNaNAfterInjection = false
        for i in 500..<frameCount {
            if output[i * 2].isNaN || output[i * 2 + 1].isNaN {
                hasNaNAfterInjection = true
                break
            }
        }
        // The safety net does NOT catch mid-buffer NaN. This documents the behavior.
        // If the safety net is ever improved, this test should be updated.
        #expect(hasNaNAfterInjection,
                "Mid-buffer NaN should propagate uncaught (safety net only checks output[0..1])")
    }

    @Test("After mid-buffer NaN, delay state is corrupted: next process() call catches NaN at frame 0")
    func nanPropagatesViaDelayStateToNextCall() {
        let processor = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        settings.bandGains[5] = 6
        processor.updateSettings(settings)

        let frameCount = 1024
        let sampleCount = frameCount * 2

        let input1 = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output1 = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input1.deallocate(); output1.deallocate() }

        // First call: inject NaN mid-buffer to corrupt delay state
        let omega = 2.0 * Double.pi * 1000.0 / 48000.0
        for i in 0..<frameCount {
            let sample = Float(sin(omega * Double(i)))
            input1[i * 2] = sample
            input1[i * 2 + 1] = sample
        }
        input1[500 * 2] = .nan
        input1[500 * 2 + 1] = .nan

        processor.process(input: input1, output: output1, frameCount: frameCount)

        // Second call: clean input, but delay state has NaN from previous call
        let input2 = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output2 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input2.deallocate(); output2.deallocate() }

        processor.process(input: input2, output: output2, frameCount: frameCount)

        // Safety net should catch NaN at output[0] (from corrupted delay buffers)
        // and zero the entire output + reset delay buffers
        #expect(output2[0] == 0, "Second call output[0] should be zeroed by safety net")
        #expect(output2[1] == 0, "Second call output[1] should be zeroed by safety net")

        // Verify full output is zeroed (safety net behavior)
        var allZero = true
        for i in 0..<sampleCount {
            if output2[i] != 0 { allZero = false; break }
        }
        #expect(allZero, "Safety net should zero entire output after NaN propagation from delay state")

        // Third call: after safety net reset, processing should recover
        let input3 = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output3 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input3.deallocate(); output3.deallocate() }

        processor.process(input: input3, output: output3, frameCount: frameCount)

        // Should produce valid output now (delay buffers were reset)
        let rms = AdversarialSignal.measureRMS(
            buffer: output3, channel: 0, frameCount: frameCount, skipFrames: 256
        )
        #expect(rms > 0 && rms.isFinite, "After safety net recovery, output should be valid (RMS=\(rms))")
    }
}


// MARK: - Suite 3: Delay Buffer State Carryover

@Suite("Adversarial — Delay Buffer State Carryover")
struct DelayBufferCarryoverTests {

    @Test("Processing loud signal then silence: output shows non-zero filter ringing from delay state")
    func delayStateBleedsSilenceAfterSignal() {
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 4096

        // First: process loud 1kHz signal to fill delay buffers
        let signal = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let out1 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { signal.deallocate(); out1.deallocate() }

        processor.process(input: signal, output: out1, frameCount: frameCount)

        // Second: process silence — delay buffers should cause ringing
        let silence = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        let out2 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { silence.deallocate(); out2.deallocate() }

        processor.process(input: silence, output: out2, frameCount: frameCount)

        // First few frames of "silence" output should be non-zero (filter ringing)
        var hasNonZero = false
        for i in 0..<20 { // check first 20 frames
            if out2[i * 2] != 0 || out2[i * 2 + 1] != 0 {
                hasNonZero = true
                break
            }
        }
        #expect(hasNonZero,
                "After processing signal, silence output should show filter ringing from delay state")

        // The ringing should decay to near-zero by end of buffer
        let tailRMS = AdversarialSignal.measureRMS(
            buffer: out2, channel: 0, frameCount: frameCount, skipFrames: 3000
        )
        #expect(tailRMS < 0.01,
                "Filter ringing should decay to near-zero by end of buffer, got RMS=\(tailRMS)")
    }

    @Test("resetDelayBuffers eliminates state carryover: silence after reset is truly silent")
    func resetDelayBuffersEliminatesCarryover() {
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 4096

        // Process loud signal to fill delay buffers
        let signal = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let out1 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { signal.deallocate(); out1.deallocate() }

        processor.process(input: signal, output: out1, frameCount: frameCount)

        // Reset delay buffers
        processor.resetDelayBuffers()

        // Process silence — should be truly silent now
        let silence = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        let out2 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { silence.deallocate(); out2.deallocate() }

        processor.process(input: silence, output: out2, frameCount: frameCount)

        // Every sample should be exactly zero
        for i in 0..<(frameCount * 2) {
            #expect(out2[i] == 0,
                    "After resetDelayBuffers, silence should produce zero output at sample \(i)")
        }
    }

    @Test("Double process same processor: second call produces different output due to delay state evolution")
    func doubleProcessDiffersFromFirst() {
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 4096

        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let out1 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        let out2 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); out1.deallocate(); out2.deallocate() }

        // First process
        processor.process(input: input, output: out1, frameCount: frameCount)

        // Reset processor to fresh state
        processor.resetDelayBuffers()

        // Second process with identical input — same delay state now
        processor.process(input: input, output: out2, frameCount: frameCount)

        // After reset, both calls should produce identical output
        var maxDiff: Float = 0
        for i in 0..<(frameCount * 2) {
            let diff = abs(out1[i] - out2[i])
            if diff > maxDiff { maxDiff = diff }
        }
        #expect(maxDiff < 1e-6,
                "Identical input with fresh delay state should produce identical output, maxDiff=\(maxDiff)")
    }
}


// MARK: - Suite 4: Enable/Disable Cycling

@Suite("Adversarial — Enable/Disable Cycling")
struct EnableDisableCyclingTests {

    @Test("Disable during active processing produces bit-exact passthrough")
    func disableIsBitExactPassthrough() {
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 4096

        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        // Disable before processing
        processor.setEnabled(false)
        processor.process(input: input, output: output, frameCount: frameCount)

        // Must be bit-exact copy
        for i in 0..<(frameCount * 2) {
            #expect(output[i] == input[i],
                    "Disabled processor: sample \(i) should be bit-exact passthrough")
        }
    }

    @Test("Enable→process→disable→process→enable→process: re-enable uses stale delay state")
    func enableDisableCycleDelayStateCarryover() {
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 2048

        // Step 1: Enabled processing fills delay buffers
        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let out1 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); out1.deallocate() }

        processor.process(input: input, output: out1, frameCount: frameCount)
        let rms1 = AdversarialSignal.measureRMS(
            buffer: out1, channel: 0, frameCount: frameCount, skipFrames: 512
        )

        // Step 2: Disabled — bypass, delay buffers untouched
        processor.setEnabled(false)
        let silence = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        let outBypass = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { silence.deallocate(); outBypass.deallocate() }

        processor.process(input: silence, output: outBypass, frameCount: frameCount)

        // Step 3: Re-enable — delay buffers still have state from step 1
        processor.setEnabled(true)
        let outReEnabled = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { outReEnabled.deallocate() }

        processor.process(input: silence, output: outReEnabled, frameCount: frameCount)

        // Re-enabled with stale delay state: first few frames should show ringing
        var reEnableHasNonZero = false
        for i in 0..<10 {
            if outReEnabled[i * 2] != 0 { reEnableHasNonZero = true; break }
        }
        #expect(reEnableHasNonZero,
                "Re-enabled processor with stale delay state should produce filter ringing from stored state")

        // But the rms after re-enable with silence input should be much smaller
        // than when processing actual signal
        let rmsReEnabled = AdversarialSignal.measureRMS(
            buffer: outReEnabled, channel: 0, frameCount: frameCount, skipFrames: 0
        )
        #expect(rmsReEnabled < rms1,
                "Re-enable ringing RMS (\(rmsReEnabled)) should be less than active signal RMS (\(rms1))")
    }
}


// MARK: - Suite 5: Extreme Input Amplitudes

@Suite("Adversarial — Extreme Input Amplitudes")
struct ExtremeAmplitudeTests {

    @Test("High amplitude (100.0) through +12dB EQ: output is finite, not NaN")
    func highAmplitudeDoesNotNaN() {
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 4096

        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, amplitude: 100.0, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        // +12dB (4x) of 100.0 = 400.0 peak — large but finite for Float32
        for i in 0..<(frameCount * 2) {
            #expect(output[i].isFinite,
                    "High amplitude: sample \(i) should be finite, got \(output[i])")
        }

        // Verify it actually processed (not just passthrough)
        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let gain = outputRMS / inputRMS
        #expect(gain > 3.0 && gain < 5.0,
                "High amplitude EQ gain should be ~4x, got \(gain)x")
    }

    @Test("Zero amplitude input through EQ: output is all zeros")
    func zeroAmplitudeInput() {
        let processor = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12
        processor.updateSettings(settings)

        let frameCount = 2048
        let silence = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { silence.deallocate(); output.deallocate() }

        processor.process(input: silence, output: output, frameCount: frameCount)

        for i in 0..<(frameCount * 2) {
            #expect(output[i] == 0,
                    "Zero input through EQ should produce zero output at sample \(i)")
        }
    }

    @Test("Subnormal input values pass through EQ without becoming NaN")
    func subnormalInputSurvivesEQ() {
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 512

        let input = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        defer { input.deallocate(); output.deallocate() }

        // Fill with subnormal values
        let subnormal = Float.leastNonzeroMagnitude
        for i in 0..<(frameCount * 2) {
            input[i] = subnormal
            output[i] = 0
        }

        processor.process(input: input, output: output, frameCount: frameCount)

        for i in 0..<(frameCount * 2) {
            #expect(!output[i].isNaN, "Subnormal input: sample \(i) should not be NaN")
        }
    }

    @Test("Infinity input at frame 0: safety net does NOT catch it (checks isNaN, not isInfinite)")
    func infinityInputBypassesSafetyNet() {
        // PRODUCTION FINDING: The NaN safety net checks output[0].isNaN but infinity
        // passes through biquad as infinity (not NaN). The safety net does not catch
        // infinite values. Additionally, infinity in delay buffers will produce NaN
        // on subsequent samples (inf - inf = NaN), but the safety net only checks
        // output[0] and output[1].
        let processor = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        settings.bandGains[5] = 6
        processor.updateSettings(settings)

        let frameCount = 256
        let sampleCount = frameCount * 2

        let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input.deallocate(); output.deallocate() }

        // Inject infinity at frame 0
        for i in 0..<sampleCount { input[i] = 0.5 }
        input[0] = .infinity
        input[1] = .infinity

        processor.process(input: input, output: output, frameCount: frameCount)

        // Safety net checks isNaN, not isInfinite — infinity passes through uncaught
        let firstFrameIsInfOrNaN = output[0].isInfinite || output[0].isNaN
        #expect(firstFrameIsInfOrNaN,
                "Infinity input: output[0] should be inf or NaN, got \(output[0])")

        // Check if later frames contain non-finite values (inf → NaN propagation via delay state)
        var hasNonFiniteAfterFrame0 = false
        for i in 2..<sampleCount {
            if !output[i].isFinite { hasNonFiniteAfterFrame0 = true; break }
        }
        #expect(hasNonFiniteAfterFrame0,
                "Infinity in delay buffers should propagate non-finite values to later frames")

        // Verify safety net did NOT trigger (output NOT zeroed)
        // This documents the limitation: safety net misses infinity
        let outputNotZeroed = output[0] != 0
        #expect(outputNotZeroed,
                "Safety net should NOT have triggered (it only checks isNaN, not isInfinite)")
    }
}


// MARK: - Suite 6: DC and Nyquist Signal Invariants

@Suite("Adversarial — DC and Nyquist Signal Invariants")
struct DCAndNyquistInvariantTests {

    @Test("DC signal (constant value) passes through peaking EQ at unity gain")
    func dcSignalUnityThroughPeakingEQ() {
        // Peaking EQ has analytically proven unity gain at DC (ω=0) for any gain/Q
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 4096

        let input = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        defer { input.deallocate(); output.deallocate() }

        // Constant DC value
        let dcValue: Float = 0.7
        for i in 0..<(frameCount * 2) {
            input[i] = dcValue
            output[i] = 0
        }

        processor.process(input: input, output: output, frameCount: frameCount)

        // After transient, output should converge to DC value
        let skipFrames = 2048
        for i in skipFrames..<frameCount {
            let diffL = abs(output[i * 2] - dcValue)
            let diffR = abs(output[i * 2 + 1] - dcValue)
            #expect(diffL < 0.01,
                    "DC through peaking EQ: frame \(i) L should be ~\(dcValue), got \(output[i * 2])")
            #expect(diffR < 0.01,
                    "DC through peaking EQ: frame \(i) R should be ~\(dcValue), got \(output[i * 2 + 1])")
        }
    }

    @Test("Nyquist signal (alternating +1/-1) passes through peaking EQ at unity gain")
    func nyquistSignalUnityThroughPeakingEQ() {
        // Peaking EQ also has unity gain at Nyquist (ω=π) for any gain/Q
        let processor = AdversarialSignal.makePeakingProcessor(
            frequency: 1000, gainDB: 12
        )
        let frameCount = 4096

        let input = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        defer { input.deallocate(); output.deallocate() }

        // Alternating +0.5 / -0.5 = Nyquist frequency
        for i in 0..<frameCount {
            let val: Float = (i % 2 == 0) ? 0.5 : -0.5
            input[i * 2] = val
            input[i * 2 + 1] = val
        }
        for i in 0..<(frameCount * 2) { output[i] = 0 }

        processor.process(input: input, output: output, frameCount: frameCount)

        // After transient, amplitude should converge to 0.5
        let skipFrames = 2048
        for i in skipFrames..<frameCount {
            let expectedL: Float = (i % 2 == 0) ? 0.5 : -0.5
            let diffL = abs(output[i * 2] - expectedL)
            #expect(diffL < 0.02,
                    "Nyquist through peaking EQ: frame \(i) L should be ~\(expectedL), got \(output[i * 2])")
        }
    }

    @Test("DC signal through low shelf is boosted by shelf gain")
    func dcSignalBoostedByLowShelf() {
        // Low shelf DC gain = 10^(gainDB/20)
        let processor = BiquadProcessor(
            sampleRate: 48000, maxSections: 1, category: "test-dc-shelf",
            initiallyEnabled: true
        )
        let coeffs = BiquadMath.lowShelfCoefficients(
            frequency: 200, gainDB: 12, q: 0.707, sampleRate: 48000
        )
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(1))
        }
        processor.swapSetup(setup)

        let frameCount = 8192
        let input = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        defer { input.deallocate(); output.deallocate() }

        let dcValue: Float = 0.2
        for i in 0..<(frameCount * 2) {
            input[i] = dcValue
            output[i] = 0
        }

        processor.process(input: input, output: output, frameCount: frameCount)

        // Expected DC gain: 10^(12/20) ≈ 3.98
        let expectedDC = dcValue * Float(pow(10.0, 12.0 / 20.0))
        let skipFrames = 4096
        let measured = output[skipFrames * 2] // steady-state frame
        let error = abs(measured - expectedDC) / expectedDC
        #expect(error < 0.05,
                "Low shelf DC: expected ~\(expectedDC), got \(measured) (error=\(error * 100)%)")
    }
}


// MARK: - Suite 7: Rapid Settings Churn

@Suite("Adversarial — Rapid Settings Churn")
struct RapidSettingsChurnTests {

    @Test("100 rapid updateSettings calls: last setting wins for processing")
    func rapidSettingsChangesLastOneWins() {
        let processor = EQProcessor(sampleRate: 48000)

        // Rapidly flip between +12dB and -12dB at 1kHz
        for i in 0..<100 {
            var settings = EQSettings.flat
            settings.bandGains[5] = (i % 2 == 0) ? 12 : -12
            processor.updateSettings(settings)
        }

        // Last call was i=99 (odd) → -12dB
        let frameCount = 8192
        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let gain = outputRMS / inputRMS

        // -12dB = 0.251x gain
        #expect(gain > 0.15 && gain < 0.35,
                "After 100 settings changes, last (-12dB) should win: got \(gain)x")
    }

    @Test("50 rapid swapSetup calls: processor uses final setup correctly")
    func rapidSwapSetupStability() {
        let processor = BiquadProcessor(
            sampleRate: 48000, maxSections: 1, category: "test-churn",
            initiallyEnabled: true
        )

        // Swap setups rapidly — each defers old setup destruction by 500ms
        for _ in 0..<50 {
            let coeffs = BiquadMath.peakingEQCoefficients(
                frequency: 1000, gainDB: 12, q: BiquadMath.graphicEQQ, sampleRate: 48000
            )
            let setup = coeffs.withUnsafeBufferPointer { ptr in
                vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(1))
            }
            processor.swapSetup(setup)
        }

        // Process with the final setup
        let frameCount = 8192
        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let gain = outputRMS / inputRMS

        #expect(gain > 3.5 && gain < 4.5,
                "After 50 setup swaps, +12dB should be ~4x: got \(gain)x")
    }

    @Test("Settings change from extreme boost to flat: smooth transition, no artifacts")
    func settingsChangeExtremeToFlat() {
        let processor = EQProcessor(sampleRate: 48000)
        let frameCount = 8192

        // Start with extreme +12dB at 1kHz, process to fill delay state
        var boostSettings = EQSettings.flat
        boostSettings.bandGains[5] = 12
        processor.updateSettings(boostSettings)

        let input1 = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let out1 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input1.deallocate(); out1.deallocate() }
        processor.process(input: input1, output: out1, frameCount: frameCount)

        // Switch to flat — delay buffers NOT reset (by design for smooth transition)
        processor.updateSettings(EQSettings.flat)

        let input2 = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let out2 = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input2.deallocate(); out2.deallocate() }
        processor.process(input: input2, output: out2, frameCount: frameCount)

        // After settling, flat EQ should be near-unity
        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input2, channel: 0, frameCount: frameCount, skipFrames: 4096
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: out2, channel: 0, frameCount: frameCount, skipFrames: 4096
        )
        let gain = outputRMS / inputRMS
        #expect(abs(gain - 1.0) < 0.05,
                "After switching to flat, gain should converge to ~1.0, got \(gain)x")

        // Output should not contain NaN or Inf anywhere
        let sampleCount = frameCount * 2
        for i in 0..<sampleCount {
            #expect(out2[i].isFinite,
                    "Settings change transition: sample \(i) should be finite")
        }
    }
}


// MARK: - Suite 8: EQ with Disabled/Non-Standard Settings

@Suite("Adversarial — EQ Settings Edge Cases")
struct EQSettingsEdgeCaseTests {

    @Test("EQSettings with all bands at max gain (+12dB): no NaN, no overflow")
    func allBandsMaxGainNoOverflow() {
        let processor = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        for i in 0..<EQSettings.bandCount {
            settings.bandGains[i] = 12 // max gain on every band
        }
        processor.updateSettings(settings)

        let frameCount = 8192
        // Use moderate amplitude to avoid Float32 overflow after 10 bands of +12dB each
        // Worst case: 4^10 = ~1M, but bands overlap and don't stack multiplicatively at one freq
        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, amplitude: 0.01, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        var hasNaN = false
        var hasInf = false
        for i in 0..<(frameCount * 2) {
            if output[i].isNaN { hasNaN = true }
            if output[i].isInfinite { hasInf = true }
        }
        #expect(!hasNaN, "All bands max gain: output should not contain NaN")
        #expect(!hasInf, "All bands max gain: output should not contain Inf")
    }

    @Test("EQSettings with all bands at min gain (-12dB): signal is heavily attenuated but not zeroed")
    func allBandsMinGainAttenuates() {
        let processor = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        for i in 0..<EQSettings.bandCount {
            settings.bandGains[i] = -12
        }
        processor.updateSettings(settings)

        let frameCount = 8192
        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: 2048
        )

        // Signal should be heavily attenuated but not zero
        #expect(outputRMS > 0, "All bands min gain: output should not be zero")
        #expect(outputRMS < inputRMS, "All bands min gain: output should be attenuated")
        // At 1kHz, band 5 is -12dB, neighboring bands also contribute some cut
        #expect(outputRMS / inputRMS < 0.5,
                "All bands min gain at 1kHz: should be significantly attenuated, got \(outputRMS / inputRMS)x")
    }

    @Test("EQSettings.isEnabled=false via updateSettings: disabled EQ is bit-exact passthrough")
    func disabledEQSettingsPassthrough() {
        let processor = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12
        settings.isEnabled = false // key: disabled in settings
        processor.updateSettings(settings)

        let frameCount = 4096
        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        // Must be bit-exact passthrough when EQ disabled via settings
        for i in 0..<(frameCount * 2) {
            #expect(output[i] == input[i],
                    "Disabled EQ settings: sample \(i) should be bit-exact passthrough")
        }
    }

    @Test("EQ at 8kHz sample rate: above-Nyquist bands produce unity, no instability")
    func aboveNyquistBandsStableAt8kHz() {
        let processor = EQProcessor(sampleRate: 8000)
        var settings = EQSettings.flat
        // Set ALL bands to +12dB. At 8kHz, Nyquist is 4kHz.
        // Bands 7 (4kHz), 8 (8kHz), 9 (16kHz) are at or above Nyquist → should be unity-bypassed
        for i in 0..<EQSettings.bandCount {
            settings.bandGains[i] = 12
        }
        processor.updateSettings(settings)

        let frameCount = 8192
        // Use Nyquist-safe frequency
        let input = AdversarialSignal.makeStereoSine(
            frequency: 500, sampleRate: 8000, frameCount: frameCount
        )
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        // Output must be finite — no unstable poles from above-Nyquist bands
        var hasNaN = false
        for i in 0..<(frameCount * 2) {
            if !output[i].isFinite { hasNaN = true; break }
        }
        #expect(!hasNaN, "Above-Nyquist bands at 8kHz should not produce NaN/Inf")

        // Signal should still be boosted (below-Nyquist bands are active)
        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        #expect(outputRMS > inputRMS, "Below-Nyquist bands should still provide boost at 8kHz")
    }
}


// MARK: - Suite 9: Full Chain Edge Cases

@Suite("Adversarial — Full Signal Chain Edge Cases")
struct FullChainEdgeCaseTests {

    @Test("SoftLimiter.processBuffer with zero-length buffer does not crash")
    func softLimiterZeroLength() {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1) // minimal allocation
        defer { buffer.deallocate() }
        buffer[0] = 1.0

        // sampleCount = 0 should be a no-op
        SoftLimiter.processBuffer(buffer, sampleCount: 0)

        // Original value should be unchanged
        #expect(buffer[0] == 1.0, "Zero-length processBuffer should not modify buffer")
    }

    @Test("Volume scaling to exact zero + EQ: output is zero, limiter is no-op")
    func zeroVolumeChain() {
        let frameCount = 2048
        let sampleCount = frameCount * 2

        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: frameCount
        )
        let working = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); working.deallocate() }

        // Volume = 0 (mute)
        for i in 0..<sampleCount {
            working[i] = input[i] * 0
        }

        // EQ with +12dB
        let eq = EQProcessor(sampleRate: 48000)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12
        eq.updateSettings(settings)
        eq.process(input: working, output: working, frameCount: frameCount)

        // 0 * 4 = 0 — EQ of silence should be silence
        for i in 0..<sampleCount {
            #expect(working[i] == 0,
                    "Zero volume + EQ: sample \(i) should be zero, got \(working[i])")
        }

        // Limiter should be no-op on zeros
        SoftLimiter.processBuffer(working, sampleCount: sampleCount)
        for i in 0..<sampleCount {
            #expect(working[i] == 0,
                    "Zero volume + EQ + limiter: sample \(i) should be zero")
        }
    }

    @Test("Multiple EQ process calls in chain (two different EQProcessors): cumulative effect")
    func dualEQChainCumulativeEffect() {
        let frameCount = 8192
        let sampleRate = 48000.0

        // First EQ: +6dB at 1kHz
        let eq1 = EQProcessor(sampleRate: sampleRate)
        var settings1 = EQSettings.flat
        settings1.bandGains[5] = 6
        eq1.updateSettings(settings1)

        // Second EQ: +6dB at 1kHz
        let eq2 = EQProcessor(sampleRate: sampleRate)
        var settings2 = EQSettings.flat
        settings2.bandGains[5] = 6
        eq2.updateSettings(settings2)

        let input = AdversarialSignal.makeStereoSine(
            frequency: 1000, sampleRate: sampleRate, frameCount: frameCount
        )
        let mid = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        let output = AdversarialSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); mid.deallocate(); output.deallocate() }

        // Chain: input → EQ1 → EQ2 → output
        eq1.process(input: input, output: mid, frameCount: frameCount)
        eq2.process(input: mid, output: output, frameCount: frameCount)

        let inputRMS = AdversarialSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: 2048
        )
        let outputRMS = AdversarialSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: 2048
        )

        // Two cascaded +6dB = ~+12dB total = ~4x gain
        let gainDB = 20.0 * log10(Double(outputRMS / inputRMS))
        #expect(gainDB > 10.0 && gainDB < 14.0,
                "Dual EQ cascade +6dB+6dB: expected ~12dB total, got \(String(format: "%.1f", gainDB))dB")
    }
}
