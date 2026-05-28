// FineTuneTests/PostAgcCompressorTests.swift

import Testing
import Foundation
@testable import FineTune

@Suite("PostAgcCompressorTests")
struct PostAgcCompressorTests {

    @Test("Default settings are applied correctly")
    func defaultSettings() {
        let settings = PostAgcCompressorSettings()
        #expect(settings.thresholdDb == -3.0)
        #expect(settings.ratio == 10.0)
        #expect(settings.attackMs == 1.0)
        #expect(settings.releaseMs == 11.6)
        #expect(settings.kneeDb == 0.1)
        #expect(settings.exponentialRelease == 0.8)
        #expect(settings.maxReleaseSpeed == 0.502502918)
        #expect(settings.releaseGateStopDb == 0.978)
        #expect(settings.enabled == true)
        
        let compressor = PostAgcCompressor(settings: settings, sampleRate: 48000)
        #expect(compressor.isEnabled == true)
        #expect(compressor.currentSettings == settings)
    }

    @Test("Signals below threshold are passed through untouched")
    func belowThresholdPassthrough() {
        let settings = PostAgcCompressorSettings(thresholdDb: -0.25, enabled: true)
        let compressor = PostAgcCompressor(settings: settings, sampleRate: 48000)
        
        // -10 dBFS peak signal
        let peakLevelDb: Float = -10.0
        let peakAmp = LoudnessEqualizerMath.dbToLinear(peakLevelDb)
        
        var input: [Float] = [peakAmp, -peakAmp, peakAmp * 0.5, -peakAmp * 0.5]
        var output = [Float](repeating: 0, count: 4)
        
        compressor.process(input: &input, output: &output, frameCount: 2, channelCount: 2)
        
        // Check output matches input exactly
        #expect(output[0] == input[0])
        #expect(output[1] == input[1])
        #expect(output[2] == input[2])
        #expect(output[3] == input[3])
    }

    @Test("Signals above threshold are compressed")
    func aboveThresholdCompression() {
        // Hard knee (kneeDb = 0) to keep math simple.
        let settings = PostAgcCompressorSettings(
            thresholdDb: -10.0,
            ratio: 4.0, // 4:1 ratio
            attackMs: 0.1, // very fast attack
            releaseMs: 1000.0,
            kneeDb: 0.0,
            exponentialRelease: 0.0,
            maxReleaseSpeed: 1.0, // no cap, for test simplicity
            releaseGateStopDb: 0.0, // disabled, for test simplicity
            enabled: true
        )
        let compressor = PostAgcCompressor(settings: settings, sampleRate: 48000)
        
        // 0 dBFS peak signal
        let peakAmp: Float = 1.0
        var input = [Float](repeating: peakAmp, count: 2000) // ~20ms at 2 channels (1000 frames)
        var output = [Float](repeating: 0, count: 2000)
        
        // Run enough frames for attack to settle
        for _ in 0..<50 {
            compressor.process(input: &input, output: &output, frameCount: 1000, channelCount: 2)
        }
        
        // Input level is 0 dBFS. Threshold is -10 dBFS. Overshoot is 10 dB.
        // With 4:1 ratio, output level above threshold is 10 / 4 = 2.5 dB.
        // So expected gain reduction is -7.5 dB.
        // Let's check that the output signal is attenuated significantly.
        let outputDb = LoudnessEqualizerMath.linearToDb(abs(output[0]))
        #expect(outputDb < -1.0)
        #expect(outputDb > -10.0)
        
        // Disable compressor and verify passthrough
        let disabledSettings = PostAgcCompressorSettings(thresholdDb: -10.0, maxReleaseSpeed: 1.0, releaseGateStopDb: 0.0, enabled: false)
        let disabledCompressor = PostAgcCompressor(settings: disabledSettings, sampleRate: 48000)
        var disabledOutput = [Float](repeating: 0, count: 2000)
        disabledCompressor.process(input: &input, output: &disabledOutput, frameCount: 1000, channelCount: 2)
        #expect(disabledOutput[0] == input[0])
    }

    @Test("Soft-knee transition math is correct")
    func softKneeTransition() {
        let settings = PostAgcCompressorSettings(
            thresholdDb: -10.0,
            ratio: 4.0,
            attackMs: 0.01, // instant attack
            kneeDb: 6.0, // 6 dB knee (-13 dBFS to -7 dBFS)
            exponentialRelease: 0.0,
            maxReleaseSpeed: 1.0, // no cap, for test simplicity
            releaseGateStopDb: 0.0, // disabled, for test simplicity
            enabled: true
        )
        let compressor = PostAgcCompressor(settings: settings, sampleRate: 48000)
        
        // Signal inside knee region: e.g. -9.0 dBFS (overshoot > 0 but within knee)
        // Let's test a couple of points and verify output changes smoothly
        let ampInsideKnee = LoudnessEqualizerMath.dbToLinear(-9.0)
        var input = [Float](repeating: ampInsideKnee, count: 200)
        var output = [Float](repeating: 0, count: 200)
        
        for _ in 0..<100 {
            compressor.process(input: &input, output: &output, frameCount: 100, channelCount: 2)
        }
        
        let outputDb = LoudnessEqualizerMath.linearToDb(abs(output[0]))
        // Since -9 dBFS is inside the soft-knee, it should have some gain reduction,
        // but less than the full ratio would dictate.
        #expect(outputDb < -9.0)
    }

    @Test("Exponential release slows down as gain reduction approaches 0")
    func exponentialReleaseBehavior() {
        // High exponential release factor (1.0) vs linear/default (0.0)
        let expSettings = PostAgcCompressorSettings(
            thresholdDb: -20.0,
            ratio: 10.0,
            attackMs: 0.1,
            releaseMs: 50.0,
            kneeDb: 0.0,
            exponentialRelease: 1.0, // strong exponential release
            maxReleaseSpeed: 1.0, // no cap, for test simplicity
            releaseGateStopDb: 0.0, // disabled, for test simplicity
            enabled: true
        )
        
        let linSettings = PostAgcCompressorSettings(
            thresholdDb: -20.0,
            ratio: 10.0,
            attackMs: 0.1,
            releaseMs: 50.0,
            kneeDb: 0.0,
            exponentialRelease: 0.0, // standard release
            maxReleaseSpeed: 1.0, // no cap, for test simplicity
            releaseGateStopDb: 0.0, // disabled, for test simplicity
            enabled: true
        )
        
        let expCompressor = PostAgcCompressor(settings: expSettings, sampleRate: 48000)
        let linCompressor = PostAgcCompressor(settings: linSettings, sampleRate: 48000)
        
        // 1. Force both into compression with a loud signal (0 dBFS)
        let loudAmp: Float = 1.0
        var inputLoud = [Float](repeating: loudAmp, count: 2000)
        var output = [Float](repeating: 0, count: 2000)
        for _ in 0..<10 {
            expCompressor.process(input: &inputLoud, output: &output, frameCount: 1000, channelCount: 2)
            linCompressor.process(input: &inputLoud, output: &output, frameCount: 1000, channelCount: 2)
        }
        
        // 2. Feed silence to trigger release phase
        var inputSilence = [Float](repeating: 0.0, count: 2000)
        
        // Process a few blocks of silence and compare the remaining attenuation (gain reduction)
        // Since releaseMs is 50ms, let's step in small blocks, e.g., 240 frames (5ms)
        var expOutputs: [Float] = []
        var linOutputs: [Float] = []
        
        for _ in 0..<20 { // 100ms total release monitoring
            // We use a tiny probe signal above 0 but below threshold to read the applied gain
            var probeInput = [Float](repeating: 0.0001, count: 2)
            var expProbeOutput = [Float](repeating: 0, count: 2)
            var linProbeOutput = [Float](repeating: 0, count: 2)
            
            expCompressor.process(input: &inputSilence, output: &output, frameCount: 100, channelCount: 2)
            linCompressor.process(input: &inputSilence, output: &output, frameCount: 100, channelCount: 2)
            
            expCompressor.process(input: &probeInput, output: &expProbeOutput, frameCount: 1, channelCount: 2)
            linCompressor.process(input: &probeInput, output: &linProbeOutput, frameCount: 1, channelCount: 2)
            
            expOutputs.append(expProbeOutput[0] / probeInput[0])
            linOutputs.append(linProbeOutput[0] / probeInput[0])
        }
        
        // Under exponential release, release gets slower as we get closer to 1.0 gain (0 dB reduction).
        // Therefore, the exponential release envelope should recover LESS of the gain toward 1.0
        // in the later stages compared to the linear release.
        // Let's verify that the exponential release gain recovery curve is distinct.
        // (i.e. exp gain should be lower/more compressed than lin gain at the end of the release phase)
        #expect(expOutputs.last! < linOutputs.last!)
    }

    @Test("NaN values in input do not propagate and are handled safely")
    func nanSafety() {
        let settings = PostAgcCompressorSettings(thresholdDb: -0.25, enabled: true)
        let compressor = PostAgcCompressor(settings: settings, sampleRate: 48000)
        
        var input: [Float] = [Float.nan, Float.nan, 0.1, -0.1]
        var output = [Float](repeating: 0, count: 4)
        
        // This should not crash, and output should be clean of NaNs for non-NaN inputs, or replaced safely.
        compressor.process(input: &input, output: &output, frameCount: 2, channelCount: 2)
        
        // Check that non-NaN inputs produce non-NaN outputs
        #expect(!output[2].isNaN)
        #expect(!output[3].isNaN)
    }
}
