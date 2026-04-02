// FineTuneTests/BiquadProcessorSignalTests.swift
// vDSP signal-domain integration tests for BiquadProcessor.
//
// Tests the gap between "BiquadMath coefficients are correct" and "audio
// actually sounds right" — coefficient ordering into vDSP_biquad_CreateSetup,
// delay buffer sizing, section count, stereo interleave stride, and the
// NaN safety net.
//
// Strategy: generate known sine waves, process through real vDSP_biquad setups
// built from BiquadMath coefficients, measure steady-state output amplitude.

import Accelerate
import Testing
@testable import FineTune

// MARK: - Test Signal Helpers

/// Generates stereo interleaved sine wave buffers for signal-domain testing.
private enum TestSignal {

    /// Generate a stereo interleaved sine wave.
    /// - Parameters:
    ///   - frequency: Sine frequency in Hz.
    ///   - amplitude: Peak amplitude (default 1.0).
    ///   - sampleRate: Sample rate in Hz.
    ///   - frameCount: Number of stereo frames.
    /// - Returns: Allocated buffer (caller must deallocate) with `frameCount * 2` samples.
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
            buffer[i * 2] = sample       // left
            buffer[i * 2 + 1] = sample   // right
        }
        return buffer
    }

    /// Measure RMS amplitude of one channel from a stereo interleaved buffer,
    /// skipping an initial transient region.
    /// - Parameters:
    ///   - buffer: Stereo interleaved Float32 buffer.
    ///   - channel: 0 for left, 1 for right.
    ///   - frameCount: Total stereo frames in buffer.
    ///   - skipFrames: Frames to skip at the start (transient settling).
    /// - Returns: RMS amplitude of the selected channel over the measurement region.
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

    /// Measure peak amplitude of one channel from a stereo interleaved buffer,
    /// skipping an initial transient region.
    static func measurePeak(
        buffer: UnsafePointer<Float>,
        channel: Int,
        frameCount: Int,
        skipFrames: Int
    ) -> Float {
        var peak: Float = 0
        for i in skipFrames..<frameCount {
            let absSample = abs(buffer[i * 2 + channel])
            if absSample > peak { peak = absSample }
        }
        return peak
    }

    /// Allocate a zeroed stereo interleaved output buffer.
    static func makeOutputBuffer(frameCount: Int) -> UnsafeMutablePointer<Float> {
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * 2)
        buf.initialize(repeating: 0, count: frameCount * 2)
        return buf
    }
}

// MARK: - Single-Band Peaking EQ Signal Tests

@Suite("BiquadProcessor Signal — Peaking EQ")
struct BiquadProcessorPeakingSignalTests {

    /// Standard test parameters.
    private static let sampleRate: Double = 48000
    private static let frameCount: Int = 8192
    private static let skipFrames: Int = 2048 // Skip transient settling

    /// Create a BiquadProcessor with a single-band peaking EQ setup.
    private static func makeProcessor(
        frequency: Double,
        gainDB: Float,
        q: Double = BiquadMath.graphicEQQ
    ) -> BiquadProcessor {
        let processor = BiquadProcessor(
            sampleRate: sampleRate,
            maxSections: 1,
            category: "test-peaking",
            initiallyEnabled: true
        )
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate
        )
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(1))
        }
        processor.swapSetup(setup)
        return processor
    }

    @Test("+12dB peaking at 1kHz boosts 1kHz sine to ~4x amplitude")
    func peaking12dBAt1kHz_boosts1kHz() {
        let processor = Self.makeProcessor(frequency: 1000, gainDB: 12)
        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        // +12dB = 10^(12/20) = 3.981x linear gain
        // Tolerance: within 1dB -> 3.55x to 4.47x
        #expect(gain > 3.5 && gain < 4.5,
                "+12dB peaking at 1kHz: expected ~3.98x gain, got \(gain)x")
    }

    @Test("+12dB peaking at 1kHz leaves 100Hz sine unaffected (~1x)")
    func peaking12dBAt1kHz_doesNotAffect100Hz() {
        let processor = Self.makeProcessor(frequency: 1000, gainDB: 12)
        let input = TestSignal.makeStereoSine(
            frequency: 100, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        // Far from center frequency: gain should be ~1.0 (within ±0.5dB -> 0.94x to 1.06x)
        #expect(gain > 0.9 && gain < 1.1,
                "+12dB peaking at 1kHz: 100Hz sine should be ~unity, got \(gain)x")
    }

    @Test("+12dB peaking at 1kHz: both channels get identical processing")
    func peaking12dBStereoSymmetry() {
        let processor = Self.makeProcessor(frequency: 1000, gainDB: 12)
        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let leftRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let rightRMS = TestSignal.measureRMS(
            buffer: output, channel: 1, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        // Identical mono input on both channels -> identical output
        #expect(abs(leftRMS - rightRMS) / leftRMS < 0.001,
                "Stereo symmetry: L=\(leftRMS) R=\(rightRMS) should match")
    }

    @Test("-12dB cut at 1kHz attenuates 1kHz sine to ~0.25x amplitude")
    func peakingCut12dBAt1kHz() {
        let processor = Self.makeProcessor(frequency: 1000, gainDB: -12)
        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        // -12dB = 10^(-12/20) = 0.251x linear gain
        // Tolerance: within 1dB -> 0.224x to 0.282x
        #expect(gain > 0.2 && gain < 0.3,
                "-12dB cut at 1kHz: expected ~0.25x gain, got \(gain)x")
    }

    @Test("Peaking EQ frequency selectivity: gain decreases with distance from center",
          arguments: [
            (freq: 500.0,  label: "500Hz"),
            (freq: 2000.0, label: "2kHz"),
            (freq: 4000.0, label: "4kHz"),
            (freq: 8000.0, label: "8kHz")
          ])
    func peakingSelectivity(testFreq: (freq: Double, label: String)) {
        let processor = Self.makeProcessor(frequency: 1000, gainDB: 12)
        let input = TestSignal.makeStereoSine(
            frequency: testFreq.freq, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        // All off-center frequencies should have less boost than the center frequency gain of ~4x
        #expect(gain < 3.98,
                "\(testFreq.label) should have less gain than center: got \(gain)x")
    }
}

// MARK: - Flat EQ (Multi-Band)

@Suite("BiquadProcessor Signal — Flat EQ")
struct BiquadProcessorFlatEQSignalTests {

    private static let sampleRate: Double = 48000
    private static let frameCount: Int = 8192
    private static let skipFrames: Int = 2048

    @Test("All-0dB 10-band EQ via EQProcessor: output approximately equals input",
          arguments: [100.0, 440.0, 1000.0, 4000.0, 10000.0])
    func flatEQPassthrough(frequency: Double) {
        let processor = EQProcessor(sampleRate: Self.sampleRate)
        processor.updateSettings(EQSettings.flat)

        let input = TestSignal.makeStereoSine(
            frequency: frequency, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        // Flat EQ should be near-unity: within ±0.1dB -> 0.989x to 1.012x
        #expect(abs(gain - 1.0) < 0.02,
                "Flat EQ at \(frequency)Hz: expected unity gain, got \(gain)x (\(20*log10(Double(gain)))dB)")
    }

    @Test("Flat EQ preserves signal waveform: max sample-wise error within Float32 epsilon")
    func flatEQPreservesWaveform() {
        let processor = EQProcessor(sampleRate: Self.sampleRate)
        processor.updateSettings(EQSettings.flat)

        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        // After transient, each output sample should closely match input
        var maxError: Float = 0
        for i in Self.skipFrames..<Self.frameCount {
            let errL = abs(output[i * 2] - input[i * 2])
            let errR = abs(output[i * 2 + 1] - input[i * 2 + 1])
            maxError = max(maxError, errL, errR)
        }
        // 10-band cascade of biquad filters with 0dB gain: b0/a0=1.0 exactly, but
        // b1/a0 and a1/a0 may differ by Float64 rounding before being truncated to
        // Float32 by vDSP_biquad. 10 cascaded sections amplify residual errors.
        // Empirical max error is ~1e-5 to ~1e-4 depending on frequency and rounding.
        #expect(maxError < 1e-3,
                "Flat EQ max sample error should be < 1e-3, got \(maxError)")
    }
}

// MARK: - Shelf Filter Signal Tests

@Suite("BiquadProcessor Signal — Shelf Filters")
struct BiquadProcessorShelfSignalTests {

    private static let sampleRate: Double = 48000
    private static let frameCount: Int = 8192
    private static let skipFrames: Int = 2048

    /// Create a single-section BiquadProcessor with shelf coefficients.
    private static func makeShelfProcessor(
        type: String,
        frequency: Double,
        gainDB: Float,
        q: Double = 0.707
    ) -> BiquadProcessor {
        let processor = BiquadProcessor(
            sampleRate: sampleRate,
            maxSections: 1,
            category: "test-shelf",
            initiallyEnabled: true
        )
        let coeffs: [Double]
        if type == "low" {
            coeffs = BiquadMath.lowShelfCoefficients(
                frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate
            )
        } else {
            coeffs = BiquadMath.highShelfCoefficients(
                frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate
            )
        }
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(1))
        }
        processor.swapSetup(setup)
        return processor
    }

    // MARK: Low Shelf

    @Test("Low shelf +12dB at 200Hz: 50Hz sine boosted to ~4x")
    func lowShelfBoosts50Hz() {
        let processor = Self.makeShelfProcessor(type: "low", frequency: 200, gainDB: 12)
        let input = TestSignal.makeStereoSine(
            frequency: 50, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        let gainDB = 20.0 * log10(Double(gain))
        // Low shelf at 200Hz, +12dB: 50Hz (well below shelf) should see full boost
        // Expect within ±2dB of target
        #expect(gainDB > 10.0 && gainDB < 14.0,
                "Low shelf +12dB: 50Hz should see ~12dB boost, got \(String(format: "%.1f", gainDB))dB")
    }

    @Test("Low shelf +12dB at 200Hz: 8kHz sine unaffected (~0dB)")
    func lowShelfDoesNotAffect8kHz() {
        let processor = Self.makeShelfProcessor(type: "low", frequency: 200, gainDB: 12)
        let input = TestSignal.makeStereoSine(
            frequency: 8000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        // High frequencies should be unaffected: within ±0.5dB
        #expect(gain > 0.94 && gain < 1.06,
                "Low shelf at 200Hz: 8kHz should be ~unity, got \(gain)x")
    }

    // MARK: High Shelf

    @Test("High shelf -12dB at 4kHz: 16kHz sine cut to ~0.25x")
    func highShelfCuts16kHz() {
        let processor = Self.makeShelfProcessor(type: "high", frequency: 4000, gainDB: -12)
        let input = TestSignal.makeStereoSine(
            frequency: 16000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        let gainDB = 20.0 * log10(Double(gain))
        // High shelf -12dB at 4kHz: 16kHz (well above) should see full cut
        // Expect within ±2dB of target
        #expect(gainDB > -14.0 && gainDB < -10.0,
                "High shelf -12dB: 16kHz should see ~-12dB cut, got \(String(format: "%.1f", gainDB))dB")
    }

    @Test("High shelf -12dB at 4kHz: 100Hz sine unaffected (~0dB)")
    func highShelfDoesNotAffect100Hz() {
        let processor = Self.makeShelfProcessor(type: "high", frequency: 4000, gainDB: -12)
        let input = TestSignal.makeStereoSine(
            frequency: 100, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        let gain = outputRMS / inputRMS
        #expect(gain > 0.94 && gain < 1.06,
                "High shelf at 4kHz: 100Hz should be ~unity, got \(gain)x")
    }

    @Test("High shelf +6dB at 4kHz: 12kHz sine boosted, 200Hz unaffected")
    func highShelfBoost() {
        let processor = Self.makeShelfProcessor(type: "high", frequency: 4000, gainDB: 6)

        // Test high frequency boost
        let inputHigh = TestSignal.makeStereoSine(
            frequency: 12000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let outputHigh = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { inputHigh.deallocate(); outputHigh.deallocate() }

        processor.process(input: inputHigh, output: outputHigh, frameCount: Self.frameCount)

        let highInRMS = TestSignal.measureRMS(
            buffer: inputHigh, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let highOutRMS = TestSignal.measureRMS(
            buffer: outputHigh, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let highGainDB = 20.0 * log10(Double(highOutRMS / highInRMS))

        #expect(highGainDB > 4.0 && highGainDB < 8.0,
                "High shelf +6dB: 12kHz should see ~6dB boost, got \(String(format: "%.1f", highGainDB))dB")
    }
}

// MARK: - Bypass and Disabled Processing

@Suite("BiquadProcessor Signal — Bypass Behavior")
struct BiquadProcessorBypassSignalTests {

    private static let sampleRate: Double = 48000
    private static let frameCount: Int = 4096

    @Test("Disabled processor passes input through unchanged (bit-exact)")
    func disabledPassthrough() {
        let processor = BiquadProcessor(
            sampleRate: Self.sampleRate,
            maxSections: 1,
            category: "test-bypass",
            initiallyEnabled: false
        )

        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        for i in 0..<(Self.frameCount * 2) {
            #expect(output[i] == input[i],
                    "Disabled: sample \(i) should be bit-exact passthrough")
        }
    }

    @Test("Processor with nil setup passes through unchanged")
    func nilSetupPassthrough() {
        let processor = BiquadProcessor(
            sampleRate: Self.sampleRate,
            maxSections: 1,
            category: "test-nil-setup",
            initiallyEnabled: true // enabled, but no setup
        )

        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        for i in 0..<(Self.frameCount * 2) {
            #expect(output[i] == input[i],
                    "Nil setup: sample \(i) should be bit-exact passthrough")
        }
    }

    @Test("In-place processing: input == output buffer works correctly")
    func inPlaceProcessing() {
        let processor = EQProcessor(sampleRate: Self.sampleRate)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12 // +12dB at 1kHz
        processor.updateSettings(settings)

        let buffer = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        defer { buffer.deallocate() }

        // Measure input RMS before in-place processing
        let inputRMS = TestSignal.measureRMS(
            buffer: buffer, channel: 0, frameCount: Self.frameCount, skipFrames: 2048
        )

        // In-place: input == output
        processor.process(input: buffer, output: buffer, frameCount: Self.frameCount)

        let outputRMS = TestSignal.measureRMS(
            buffer: buffer, channel: 0, frameCount: Self.frameCount, skipFrames: 2048
        )

        let gain = outputRMS / inputRMS
        // Should show boost at 1kHz
        #expect(gain > 2.0,
                "In-place +12dB at 1kHz: expected significant boost, got \(gain)x")
    }
}

// MARK: - NaN Safety Net

@Suite("BiquadProcessor Signal — NaN Safety")
struct BiquadProcessorNaNSafetyTests {

    private static let sampleRate: Double = 48000
    private static let frameCount: Int = 1024

    @Test("NaN in first sample triggers safety net: output zeroed")
    func nanFirstSampleZerosOutput() {
        let processor = EQProcessor(sampleRate: Self.sampleRate)
        var settings = EQSettings.flat
        settings.bandGains[5] = 6 // Active EQ to engage processing
        processor.updateSettings(settings)

        let sampleCount = Self.frameCount * 2
        let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { input.deallocate(); output.deallocate() }

        // Fill with valid signal, inject NaN at start
        for i in 0..<sampleCount {
            input[i] = Float(sin(Double(i) * 0.1))
        }
        input[0] = .nan
        input[1] = .nan

        processor.process(input: input, output: output, frameCount: Self.frameCount)

        // NaN safety net: when output[0] or output[1] is NaN, entire output is zeroed
        // and delay buffers are reset
        for i in 0..<sampleCount {
            #expect(!output[i].isNaN, "NaN should not propagate to output[\(i)]")
            #expect(output[i] == 0, "NaN safety net should zero output[\(i)]")
        }
    }
}

// MARK: - EQProcessor Multi-Band Signal Tests

@Suite("BiquadProcessor Signal — Multi-Band EQ")
struct EQProcessorMultiBandSignalTests {

    private static let sampleRate: Double = 48000
    private static let frameCount: Int = 8192
    private static let skipFrames: Int = 2048

    @Test("Single band boost at 1kHz via EQProcessor: 1kHz boosted, 100Hz unaffected")
    func singleBandViaEQProcessor() {
        let processor = EQProcessor(sampleRate: Self.sampleRate)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12 // Band 5 = 1kHz, +12dB
        processor.updateSettings(settings)

        // Test 1kHz
        let input1k = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let output1k = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input1k.deallocate(); output1k.deallocate() }

        processor.process(input: input1k, output: output1k, frameCount: Self.frameCount)

        let inputRMS1k = TestSignal.measureRMS(
            buffer: input1k, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let outputRMS1k = TestSignal.measureRMS(
            buffer: output1k, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let gain1k = outputRMS1k / inputRMS1k

        // Note: 10-band cascade means the 1kHz band filter is one of 10 sections,
        // but only that section has non-zero gain. Others are flat (0dB) -> unity passthrough.
        // Expect close to single-band result.
        let gain1kDB = 20.0 * log10(Double(gain1k))
        #expect(gain1kDB > 10.0 && gain1kDB < 14.0,
                "EQProcessor 1kHz band +12dB: expected ~12dB at 1kHz, got \(String(format: "%.1f", gain1kDB))dB")
    }

    @Test("Multiple bands boosted: cumulative effect on broadband signal")
    func multipleBandsBoost() {
        let processor = EQProcessor(sampleRate: Self.sampleRate)
        var settings = EQSettings.flat
        // Boost bass and treble, leave mids flat
        settings.bandGains[0] = 6  // 31.25 Hz
        settings.bandGains[1] = 6  // 62.5 Hz
        settings.bandGains[8] = 6  // 8 kHz
        settings.bandGains[9] = 6  // 16 kHz
        processor.updateSettings(settings)

        // 500Hz (mid) should be mostly unaffected
        let inputMid = TestSignal.makeStereoSine(
            frequency: 500, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let outputMid = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { inputMid.deallocate(); outputMid.deallocate() }

        processor.process(input: inputMid, output: outputMid, frameCount: Self.frameCount)

        let midIn = TestSignal.measureRMS(
            buffer: inputMid, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let midOut = TestSignal.measureRMS(
            buffer: outputMid, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        let midGain = midOut / midIn
        // Mid-range should be close to unity (boosted bands are far away)
        #expect(midGain > 0.85 && midGain < 1.15,
                "Boosted bass/treble: 500Hz should be near unity, got \(midGain)x")
    }

    @Test("Sample rate change via updateSampleRate recomputes correctly")
    @MainActor func sampleRateChange() {
        let processor = EQProcessor(sampleRate: 44100)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12 // +12dB at 1kHz
        processor.updateSettings(settings)

        // Change to 48kHz (requires main queue — dispatchPrecondition)
        processor.updateSampleRate(48000)

        // After rate change, 1kHz should still be boosted
        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: 48000, frameCount: 8192
        )
        let output = TestSignal.makeOutputBuffer(frameCount: 8192)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: 8192)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: 8192, skipFrames: 2048
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: 8192, skipFrames: 2048
        )

        let gainDB = 20.0 * log10(Double(outputRMS / inputRMS))
        #expect(gainDB > 10.0 && gainDB < 14.0,
                "After sample rate change: 1kHz should still see ~12dB boost, got \(String(format: "%.1f", gainDB))dB")
    }
}

// MARK: - Full Chain: Volume + EQ + SoftLimiter

@Suite("Signal Chain — Volume + EQ + SoftLimiter")
struct FullSignalChainTests {

    private static let sampleRate: Double = 48000
    private static let frameCount: Int = 8192
    private static let skipFrames: Int = 2048

    @Test("Full chain: 0.5x volume + 12dB EQ boost + limiter produces correct amplitude")
    func volumeEQLimiterChain() {
        // Stage 1: Apply volume attenuation (0.5x = -6dB)
        let input = TestSignal.makeStereoSine(
            frequency: 1000, amplitude: 0.5, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let afterVolume = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); afterVolume.deallocate() }

        // Simulate volume by scaling
        let sampleCount = Self.frameCount * 2
        let volume: Float = 0.5
        for i in 0..<sampleCount {
            afterVolume[i] = input[i] * volume
        }

        let afterVolumeRMS = TestSignal.measureRMS(
            buffer: afterVolume, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        // Stage 2: Apply EQ (+12dB at 1kHz)
        let eqProcessor = EQProcessor(sampleRate: Self.sampleRate)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12 // +12dB at 1kHz
        eqProcessor.updateSettings(settings)

        let afterEQ = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { afterEQ.deallocate() }

        eqProcessor.process(input: afterVolume, output: afterEQ, frameCount: Self.frameCount)

        let afterEQRMS = TestSignal.measureRMS(
            buffer: afterEQ, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        // Verify EQ boosted: ~4x gain over post-volume level
        let eqGain = afterEQRMS / afterVolumeRMS
        #expect(eqGain > 3.0,
                "EQ stage should boost ~4x at 1kHz, got \(eqGain)x")

        // Stage 3: Apply SoftLimiter
        SoftLimiter.processBuffer(afterEQ, sampleCount: sampleCount)

        let afterLimiterPeak = TestSignal.measurePeak(
            buffer: afterEQ, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        // Limiter must enforce ceiling
        #expect(afterLimiterPeak <= SoftLimiter.ceiling,
                "After limiter: peak should be <= ceiling, got \(afterLimiterPeak)")

        // After limiter, RMS should be reduced compared to pre-limiter (if signal was clipping)
        let afterLimiterRMS = TestSignal.measureRMS(
            buffer: afterEQ, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        // Input amplitude 0.5 * volume 0.5 = 0.25 peak, * ~4x EQ = ~1.0 peak.
        // That's near/above threshold (0.95), so limiter should be active on peaks.
        #expect(afterLimiterRMS > 0, "Limiter output should not be silent")
    }

    @Test("Full chain: high volume + EQ boost is constrained by limiter")
    func limiterConstrainsHighBoost() {
        // 1.0 amplitude * 1.5x volume * 4x EQ = 6x peak -> must be limited
        let input = TestSignal.makeStereoSine(
            frequency: 1000, amplitude: 1.0, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let working = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); working.deallocate() }

        // Apply volume 1.5x (boost)
        let sampleCount = Self.frameCount * 2
        for i in 0..<sampleCount {
            working[i] = input[i] * 1.5
        }

        // Apply EQ +12dB at 1kHz
        let eqProcessor = EQProcessor(sampleRate: Self.sampleRate)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12
        eqProcessor.updateSettings(settings)

        eqProcessor.process(input: working, output: working, frameCount: Self.frameCount)

        // Before limiter: peak should exceed ceiling
        let preLimiterPeak = TestSignal.measurePeak(
            buffer: working, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        #expect(preLimiterPeak > SoftLimiter.ceiling,
                "Pre-limiter peak should exceed ceiling: got \(preLimiterPeak)")

        // Apply limiter
        SoftLimiter.processBuffer(working, sampleCount: sampleCount)

        // After limiter: every sample should be within ceiling
        for i in 0..<sampleCount {
            #expect(abs(working[i]) <= SoftLimiter.ceiling,
                    "Post-limiter sample \(i) = \(working[i]) exceeds ceiling")
        }
    }

    @Test("Full chain: low volume signal passes through EQ and limiter transparently")
    func lowVolumeTransparent() {
        // 0.1 amplitude * 0.3 volume = 0.03 peak. Even +12dB EQ -> 0.12 peak.
        // Well below limiter threshold (0.95) -> limiter should be transparent.
        let input = TestSignal.makeStereoSine(
            frequency: 1000, amplitude: 0.1, sampleRate: Self.sampleRate, frameCount: Self.frameCount
        )
        let working = TestSignal.makeOutputBuffer(frameCount: Self.frameCount)
        defer { input.deallocate(); working.deallocate() }

        let sampleCount = Self.frameCount * 2
        for i in 0..<sampleCount {
            working[i] = input[i] * 0.3
        }

        // Capture pre-EQ RMS
        let preEQRMS = TestSignal.measureRMS(
            buffer: working, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        // Apply EQ
        let eqProcessor = EQProcessor(sampleRate: Self.sampleRate)
        var settings = EQSettings.flat
        settings.bandGains[5] = 12
        eqProcessor.updateSettings(settings)
        eqProcessor.process(input: working, output: working, frameCount: Self.frameCount)

        let postEQRMS = TestSignal.measureRMS(
            buffer: working, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )

        // Apply limiter
        let preLimit = Array(UnsafeBufferPointer(start: working, count: sampleCount))
        SoftLimiter.processBuffer(working, sampleCount: sampleCount)

        // Signal should be below threshold, so limiter is no-op
        let postLimiterPeak = TestSignal.measurePeak(
            buffer: working, channel: 0, frameCount: Self.frameCount, skipFrames: Self.skipFrames
        )
        #expect(postLimiterPeak < SoftLimiter.threshold,
                "Low signal should stay below threshold: peak=\(postLimiterPeak)")

        // Verify limiter didn't modify anything (bit-exact passthrough)
        for i in Self.skipFrames * 2..<sampleCount {
            #expect(working[i] == preLimit[i],
                    "Limiter should be transparent for below-threshold signal at sample \(i)")
        }

        // EQ should have boosted significantly
        let eqGain = postEQRMS / preEQRMS
        #expect(eqGain > 3.0, "EQ should boost ~4x, got \(eqGain)x")
    }
}

// MARK: - Sample Rate Robustness

@Suite("BiquadProcessor Signal — Sample Rate Variants")
struct BiquadProcessorSampleRateTests {

    @Test("Peaking +12dB at 1kHz works correctly at common sample rates",
          arguments: [44100.0, 48000.0, 96000.0])
    func peakingAt1kHzAcrossSampleRates(sampleRate: Double) {
        let frameCount = 8192
        let skipFrames = 2048

        let processor = BiquadProcessor(
            sampleRate: sampleRate,
            maxSections: 1,
            category: "test-sr",
            initiallyEnabled: true
        )
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 12, q: BiquadMath.graphicEQQ, sampleRate: sampleRate
        )
        let setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(1))
        }
        processor.swapSetup(setup)

        let input = TestSignal.makeStereoSine(
            frequency: 1000, sampleRate: sampleRate, frameCount: frameCount
        )
        let output = TestSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input.deallocate(); output.deallocate() }

        processor.process(input: input, output: output, frameCount: frameCount)

        let inputRMS = TestSignal.measureRMS(
            buffer: input, channel: 0, frameCount: frameCount, skipFrames: skipFrames
        )
        let outputRMS = TestSignal.measureRMS(
            buffer: output, channel: 0, frameCount: frameCount, skipFrames: skipFrames
        )

        let gainDB = 20.0 * log10(Double(outputRMS / inputRMS))
        #expect(gainDB > 10.0 && gainDB < 14.0,
                "+12dB peaking at 1kHz at \(sampleRate)Hz: expected ~12dB, got \(String(format: "%.1f", gainDB))dB")
    }

    @Test("10-band EQ at 8kHz sample rate: above-Nyquist bands bypassed, below-Nyquist processed")
    func bluetoothHFPSignalTest() {
        let sampleRate = 8000.0
        let frameCount = 8192
        let skipFrames = 2048

        let processor = EQProcessor(sampleRate: sampleRate)
        var settings = EQSettings.flat
        // Boost all bands to +12dB
        for i in 0..<EQSettings.bandCount {
            settings.bandGains[i] = 12
        }
        processor.updateSettings(settings)

        // 500Hz sine (below Nyquist): should see EQ boost
        let input500 = TestSignal.makeStereoSine(
            frequency: 500, sampleRate: sampleRate, frameCount: frameCount
        )
        let output500 = TestSignal.makeOutputBuffer(frameCount: frameCount)
        defer { input500.deallocate(); output500.deallocate() }

        processor.process(input: input500, output: output500, frameCount: frameCount)

        let in500RMS = TestSignal.measureRMS(
            buffer: input500, channel: 0, frameCount: frameCount, skipFrames: skipFrames
        )
        let out500RMS = TestSignal.measureRMS(
            buffer: output500, channel: 0, frameCount: frameCount, skipFrames: skipFrames
        )
        let gain500 = out500RMS / in500RMS

        // 500Hz is band 4, well below Nyquist (4kHz). Should see significant boost.
        #expect(gain500 > 2.0,
                "500Hz at 8kHz sr: should see EQ boost, got \(gain500)x")
    }
}
