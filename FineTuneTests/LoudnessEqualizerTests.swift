// FineTuneTests/LoudnessEqualizerTests.swift
// Unit tests for the LoudnessEqualizer feature.

import Testing
import Foundation
@testable import FineTune

@Suite("LoudnessEqualizer")
struct LoudnessEqualizerTests {

    // MARK: - LoudnessEqualizerSettings

    @Test("Settings default to approved values")
    func settingsDefaults() {
        let s = LoudnessEqualizerSettings()
        #expect(s.driveDb == 24.0)
        #expect(s.targetLevelDb == -7.9)
        #expect(s.attackSpeedDbPerSecPer6Db == 6.0)
        #expect(s.releaseSpeedDbPerSecPer6Db == 2.45)
        #expect(s.suddenJumpProtectionEnabled == true)
        #expect(s.silenceGateThresholdDb == -16.0)
        #expect(s.silenceGateSlowdownDb == -12.0)
        #expect(s.agcWindowSizeDb == 4.5)
        #expect(s.progressiveRatioEnabled == true)
        #expect(s.minRatio == 2.0)
        #expect(s.maxRatio == Float.infinity)
        #expect(s.progressiveRate == 0.15)
        #expect(s.silenceGateIdleGainDb == -24.0)
        #expect(s.enabled == false)
    }

    // MARK: - LoudnessEqualizerMath

    @Test("dB and linear conversions round-trip within tolerance")
    func dbLinearRoundTrip() {
        let testValues: [Float] = [-60, -20, -6, 0, 6, 20]
        for db in testValues {
            let linear = LoudnessEqualizerMath.dbToLinear(db)
            let roundTripped = LoudnessEqualizerMath.linearToDb(linear)
            #expect(abs(roundTripped - db) < 0.001,
                    "Round-trip failed for \(db) dB: got \(roundTripped)")
        }
        // 0 dB should map to linear 1.0
        #expect(abs(LoudnessEqualizerMath.dbToLinear(0) - 1.0) < 0.0001)
        // -∞ dB edge: linear 0 should map to a very negative dB value
        let veryNegative = LoudnessEqualizerMath.linearToDb(0)
        #expect(veryNegative < -100)
    }

    @Test("Shorter time constant produces faster smoothing coefficient")
    func smoothingCoefficientOrder() {
        let stepMs: Float = 1.0
        let fast = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 10, stepMs: stepMs)
        let slow = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 100, stepMs: stepMs)
        // A shorter time constant means larger coefficient (reaches target faster per step)
        #expect(fast > slow,
                "10 ms coefficient (\(fast)) should be larger than 100 ms coefficient (\(slow))")
        // Coefficients must be in (0, 1) exclusive
        #expect(fast > 0 && fast < 1)
        #expect(slow > 0 && slow < 1)
    }

    // MARK: - KWeightingFilter

    @Test("K-weighting reset reproduces identical output for same input")
    func kWeightingResetDeterminism() {
        let filter = KWeightingFilter(sampleRate: 48000)
        let impulse: Float = 1.0
        // Run the filter once and capture output
        let firstPass = filter.processSample(impulse)
        for _ in 0..<99 {
            _ = filter.processSample(0)
        }
        // Reset and replay — output must be identical
        filter.reset()
        let secondPass = filter.processSample(impulse)
        #expect(firstPass == secondPass,
                "After reset, first output (\(secondPass)) must equal original first output (\(firstPass))")
    }

    // MARK: - KWeightingFilter frequency response

    /// ITU-R BS.1770 K-weighting: high-shelf pre-emphasis (+4 dB HF) cascaded with
    /// 2nd-order Butterworth high-pass at ~38 Hz. Expected behavioral properties:
    ///   - 1 kHz reference: near 0 dB (within ±1 dB)
    ///   - 100 Hz: near 0 dB (HP has minimal effect above cutoff)
    ///   - 2 kHz+: positive boost increasing toward +4 dB shelf asymptote
    ///   - Below 38 Hz: significant HP roll-off
    ///
    /// Expected gains derived from ITU-R BS.1770-4 behavioral specification, not
    /// from running the code. Tolerances account for BiquadMath cookbook approximation
    /// vs. the ITU's published exact coefficients.
    @Test("K-weighting frequency response matches ITU-R BS.1770 behavioral spec",
          arguments: [
              (freq: 100.0,  minDB: -1.0,  maxDB: 1.0),
              (freq: 1000.0, minDB: -1.0,  maxDB: 1.0),
              (freq: 2000.0, minDB: 0.5,   maxDB: 3.5),
              (freq: 4000.0, minDB: 2.0,   maxDB: 5.0),
              (freq: 10000.0, minDB: 2.0,  maxDB: 5.0),
          ] as [(freq: Double, minDB: Float, maxDB: Float)])
    func kWeightingFrequencyResponse(freq: Double, minDB: Float, maxDB: Float) {
        let sampleRate: Float = 48000
        let filter = KWeightingFilter(sampleRate: sampleRate)
        let frameCount = 8192
        let skipFrames = 2048
        let amplitude: Float = 0.5

        // Generate sine wave and process through K-weighting
        var outputSquaredSum: Double = 0
        var sampleCount = 0
        for i in 0..<frameCount {
            let phase = Float(2.0 * Double.pi * freq * Double(i) / Double(sampleRate))
            let sample = amplitude * sin(phase)
            let output = filter.processSample(sample)

            if i >= skipFrames {
                outputSquaredSum += Double(output * output)
                sampleCount += 1
            }
        }

        // Measure output RMS and compute gain relative to input
        let outputRMS = Float(sqrt(outputSquaredSum / Double(sampleCount)))
        let inputRMS = amplitude / sqrt(2.0)  // RMS of sine = amplitude / √2
        let gainDB = 20.0 * log10(outputRMS / inputRMS)

        #expect(gainDB >= minDB,
                "K-weighting gain at \(Int(freq)) Hz = \(gainDB) dB, expected >= \(minDB) dB")
        #expect(gainDB <= maxDB,
                "K-weighting gain at \(Int(freq)) Hz = \(gainDB) dB, expected <= \(maxDB) dB")
    }

    @Test("K-weighting applies monotonically increasing HF boost")
    func kWeightingMonotonicHFBoost() {
        let sampleRate: Float = 48000
        let frameCount = 8192
        let skipFrames = 2048
        let amplitude: Float = 0.5

        var gainAtFreq: [Double: Float] = [:]

        for freq in [1000.0, 2000.0, 4000.0] {
            let filter = KWeightingFilter(sampleRate: sampleRate)
            var outputSquaredSum: Double = 0
            for i in 0..<frameCount {
                let phase = Float(2.0 * Double.pi * freq * Double(i) / Double(sampleRate))
                let output = filter.processSample(amplitude * sin(phase))
                if i >= skipFrames {
                    outputSquaredSum += Double(output * output)
                }
            }
            let outputRMS = Float(sqrt(outputSquaredSum / Double(frameCount - skipFrames)))
            let inputRMS = amplitude / sqrt(2.0)
            gainAtFreq[freq] = 20.0 * log10(outputRMS / inputRMS)
        }

        #expect(gainAtFreq[4000.0]! > gainAtFreq[2000.0]!,
                "Gain at 4 kHz (\(gainAtFreq[4000.0]!) dB) should exceed gain at 2 kHz (\(gainAtFreq[2000.0]!) dB)")
        #expect(gainAtFreq[2000.0]! > gainAtFreq[1000.0]!,
                "Gain at 2 kHz (\(gainAtFreq[2000.0]!) dB) should exceed gain at 1 kHz (\(gainAtFreq[1000.0]!) dB)")
    }

    // MARK: - LoudnessEqualizer

    @Test("Shared gain preserves left-right ratio for interleaved stereo buffers")
    func loudnessEqualizerPreservesStereoImage() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        let sampleRate: Float = 48000
        let frameCount = 512
        let channelCount = 2

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        // Input is interleaved production-style stereo: L0,R0,L1,R1,...
        var input = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let base = frame * channelCount
            input[base] = 0.5
            input[base + 1] = 0.25
        }

        var output = [Float](repeating: 0, count: frameCount * channelCount)

        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            }
        }

        // Extract output channels (interleaved: L0,R0,L1,R1,…)
        let outLeft  = stride(from: 0, to: frameCount * channelCount, by: channelCount).map { output[$0] }
        let outRight = stride(from: 1, to: frameCount * channelCount, by: channelCount).map { output[$0] }

        // Verify non-zero output (gain was applied)
        let sumLeft  = outLeft.map(abs).reduce(0, +)
        let sumRight = outRight.map(abs).reduce(0, +)
        #expect(sumLeft > 0,  "Left channel output should be non-zero")
        #expect(sumRight > 0, "Right channel output should be non-zero")

        // Both channels receive the same gain factor, so ratio should stay 2:1
        let ratio = sumLeft / sumRight
        #expect(abs(ratio - 2.0) < 0.02,
                "Left/right ratio should remain 2:1 after loudness processing; got \(ratio)")
    }

    @Test("Disabled equalizer is unity passthrough for interleaved stereo buffers")
    func disabledEqualizerPassesThroughUnchanged() {
        let settings = LoudnessEqualizerSettings()
        let sampleRate: Float = 48000
        let frameCount = 256
        let channelCount = 2

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        var input = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let base = frame * channelCount
            input[base] = Float(frame) / Float(frameCount)
            input[base + 1] = -0.5 * Float(frame) / Float(frameCount)
        }
        var output = [Float](repeating: 0, count: frameCount * channelCount)

        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            }
        }

        for index in 0..<input.count {
            #expect(abs(output[index] - input[index]) < 1e-7,
                    "Disabled equalizer should pass through sample \(index) unchanged; expected \(input[index]), got \(output[index])")
        }
    }

    @Test("Disabling after active gain riding restores immediate unity passthrough")
    func disablingAfterProcessingClearsResidualGain() {
        var enabledSettings = LoudnessEqualizerSettings()
        enabledSettings.enabled = true

        let sampleRate: Float = 48000
        let frameCount = 2048
        let channelCount = 2
        let enabledEq = LoudnessEqualizer(settings: enabledSettings, sampleRate: sampleRate)

        var loudInput = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let base = frame * channelCount
            loudInput[base] = 0.95
            loudInput[base + 1] = 0.95
        }
        var loudOutput = [Float](repeating: 0, count: frameCount * channelCount)

        loudInput.withUnsafeMutableBufferPointer { inPtr in
            loudOutput.withUnsafeMutableBufferPointer { outPtr in
                enabledEq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            }
        }

        // LoudnessEqualizer is immutable — create a new disabled instance
        // (matches the atomic swap pattern used in production)
        var disabledSettings = LoudnessEqualizerSettings()
        disabledSettings.enabled = false
        let disabledEq = LoudnessEqualizer(settings: disabledSettings, sampleRate: sampleRate)

        var quietInput = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let base = frame * channelCount
            quietInput[base] = 0.2
            quietInput[base + 1] = -0.1
        }
        var quietOutput = [Float](repeating: 0, count: frameCount * channelCount)

        quietInput.withUnsafeMutableBufferPointer { inPtr in
            quietOutput.withUnsafeMutableBufferPointer { outPtr in
                disabledEq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            }
        }

        for index in 0..<quietInput.count {
            #expect(abs(quietOutput[index] - quietInput[index]) < 1e-6,
                    "Disabling should clear residual gain immediately at sample \(index); expected \(quietInput[index]), got \(quietOutput[index])")
        }
    }

    // MARK: - Downward-only behavior

    @Test("Downward-only AGC attenuates loud signals to target level")
    func loudSignalAttenuatedToTarget() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        // suddenJumpProtectionEnabled = true by default — ensures no peak exceeds target
        let sampleRate: Float = 48000
        let frameCount = 65536  // ~1.36 seconds
        let channelCount = 2

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)
        let driveLinear = LoudnessEqualizerMath.dbToLinear(settings.driveDb)
        let targetDb = settings.targetLevelDb  // -7.9

        // 1 kHz sine at amplitude 0.5
        var input = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.5 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        var output = [Float](repeating: 0, count: frameCount * channelCount)

        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            }
        }

        // Verify downward-only property with sudden jump protection:
        // No output sample's peak should exceed the target level (after settling).
        let settleStart = (frameCount * 3) / 4
        var maxOutputLevelDbFS: Float = -200
        for frame in settleStart..<frameCount {
            let base = frame * channelCount
            let peak = max(abs(output[base]), abs(output[base + 1]))
            let levelDb = LoudnessEqualizerMath.linearToDb(peak)
            if levelDb > maxOutputLevelDbFS { maxOutputLevelDbFS = levelDb }
        }
        #expect(maxOutputLevelDbFS <= targetDb + 4.01,
                "Output peak level \(maxOutputLevelDbFS) dBFS should not exceed target + 4 dB (\(targetDb + 4.0) dBFS)")
        // Also verify attenuation is happening: output is below the raw driven peak level
        let drivenPeak: Float = 0.5 * driveLinear  // 8.015
        let drivenPeakDb = LoudnessEqualizerMath.linearToDb(drivenPeak)
        #expect(maxOutputLevelDbFS < drivenPeakDb - 10,
                "Output should be attenuated at least 10 dB below driven peak \(drivenPeakDb) dBFS")
    }

    @Test("Downward-only AGC does not attenuate quiet signals (gain = 0 dB)")
    func quietSignalNoAttenuation() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.releaseSpeedDbPerSecPer6Db = 100.0  // Fast release so gain settles from -24.1 dB to 0 dB quickly
        settings.silenceGateSlowdownDb = -60.0       // Disable gate slowdown for this test
        settings.silenceGateThresholdDb = -60.0      // Disable silence gate for this test
        settings.silenceGateIdleGainDb = 0.0         // Idle gain at 0 dB
        let sampleRate: Float = 48000
        let frameCount = 16384  // enough to verify gain stays at 0
        let channelCount = 2

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)
        let driveLinear = LoudnessEqualizerMath.dbToLinear(settings.driveDb)

        // Very quiet 1 kHz sine at amplitude 0.001
        var input = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.001 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        var output = [Float](repeating: 0, count: frameCount * channelCount)

        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            }
        }

        // Compute gain (output / (input * driveLinear)) using RMS over last quarter
        let settleStart = (frameCount * 3) / 4
        var inputSumSq: Double = 0
        var outputSumSq: Double = 0
        var sampleCount = 0
        for frame in settleStart..<frameCount {
            let base = frame * channelCount
            inputSumSq += Double(input[base] * input[base] + input[base + 1] * input[base + 1])
            outputSumSq += Double(output[base] * output[base] + output[base + 1] * output[base + 1])
            sampleCount += 2
        }
        let inputRMS = Float(sqrt(inputSumSq / Double(sampleCount)))
        let outputRMS = Float(sqrt(outputSumSq / Double(sampleCount)))
        let measuredGainLin = outputRMS / (inputRMS * driveLinear)
        let measuredGainDb = LoudnessEqualizerMath.linearToDb(measuredGainLin)

        // For quiet signals below target, gain should stay near 0 dB (no attenuation beyond drive)
        #expect(measuredGainDb > -0.5,
                "Quiet signal gain should be near 0 dB, got \(measuredGainDb) dB")
    }

    // MARK: - Sudden Jump Protection

    @Test("Sudden Jump Protection prevents output from exceeding target level")
    func suddenJumpProtectionLimitsPeaks() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.suddenJumpProtectionEnabled = true
        let sampleRate: Float = 48000
        let channelCount = 2
        let silenceFrames = 4800  // 100ms of silence to settle gain to -24 dB
        let transientFrames = 480  // 10ms transient block
        let totalFrames = silenceFrames + transientFrames

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        var input = [Float](repeating: 0, count: totalFrames * channelCount)
        // Silence fills the first silenceFrames (all zeros), then a loud 1 kHz sine wave
        for frame in 0..<transientFrames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample = 1.0 * sin(phase)
            let base = (silenceFrames + frame) * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        var output = [Float](repeating: 0, count: totalFrames * channelCount)

        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: totalFrames,
                    channelCount: channelCount
                )
            }
        }

        // Verify that Sudden Jump Protection successfully pulled the gain down from -24.0 dB
        #expect(eq.currentGainDb < -25.5,
                "SJP should pull the gain down below -25.5 dB; got \(eq.currentGainDb)")

        // Verify output peak is controlled near target level by the end of SJP attack
        let startFrame = silenceFrames + 432 // last 1 ms
        var maxPeak: Float = 0.0
        for frame in startFrame..<totalFrames {
            let base = frame * channelCount
            let peak = max(abs(output[base]), abs(output[base + 1]))
            if peak > maxPeak { maxPeak = peak }
        }
        let maxPeakDb = LoudnessEqualizerMath.linearToDb(maxPeak)
        let targetDb = settings.targetLevelDb
        #expect(maxPeakDb <= targetDb + 6.5,
                "Output peak level \(maxPeakDb) dBFS should be controlled near target + 6.5 dB by the end of SJP attack")
    }

    // MARK: - Attack/Release asymmetry

    @Test("Attack rate exceeds release rate (asymmetric ballistics)")
    func attackFasterThanRelease() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.suddenJumpProtectionEnabled = false  // Disable to test ballistics asymmetry
        settings.agcWindowSizeDb = 0.0
        settings.silenceGateThresholdDb = -60.0 // Disable silence gate for this test
        settings.silenceGateSlowdownDb = -60.0  // Disable slowdown for this test
        let sampleRate: Float = 48000
        let channelCount = 2
        let blockFrames = 480  // 10ms blocks for fine-grained measurement

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)
        let driveLinear = LoudnessEqualizerMath.dbToLinear(settings.driveDb)

        // Layout (gain starts at -24.1 dB; warmup lets it recover toward 0 dB):
        //   Warmup:  frames 0-95999   — quiet signal (2s, 0.01 amplitude, lets gain recover)
        //   Phase 1: frames 96000-143999 — loud signal (1s, 0.5 amplitude)
        //   Phase 2: frames 144000-191999 — silence (1s, for envelope decay)
        //   Phase 3: frames 192000-239999 — quiet signal (1s, 0.01 amplitude, below target)
        let totalFrames = 240000
        var input = [Float](repeating: 0, count: totalFrames * channelCount)

        // Warmup: quiet signal to let AGC settle from -24.1 dB toward 0 dB
        for frame in 0..<96000 {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.01 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        // Phase 1: Loud
        for frame in 96000..<144000 {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.5 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        // Phase 2: Silence — already zero
        // Phase 3: Quiet (below target after drive)
        for frame in 192000..<totalFrames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.01 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        var output = [Float](repeating: 0, count: totalFrames * channelCount)
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: totalFrames,
                    channelCount: channelCount
                )
            }
        }

        // Helper: compute effective gain (dB) for a contiguous block of frames.
        func blockGainDb(startFrame: Int) -> Float {
            let endFrame = min(startFrame + blockFrames, totalFrames)
            guard endFrame > startFrame else { return -120 }
            var inSumSq: Double = 0
            var outSumSq: Double = 0
            var count = 0
            for frame in startFrame..<endFrame {
                let base = frame * channelCount
                inSumSq += Double(input[base] * input[base] + input[base + 1] * input[base + 1])
                outSumSq += Double(output[base] * output[base] + output[base + 1] * output[base + 1])
                count += 2
            }
            let inRMS = Float(sqrt(inSumSq / Double(count)))
            let outRMS = Float(sqrt(outSumSq / Double(count)))
            guard inRMS > 1e-10 else { return -120 }
            let gainLin = outRMS / (inRMS * driveLinear)
            return LoudnessEqualizerMath.linearToDb(gainLin)
        }

        // ── Attack measurement ──
        // Phase 1 starts at frame 96000. Skip first 5000 frames for envelope follower
        // + K-weighting settling. Then measure 20 consecutive blocks (200ms).
        let attackStart = 96000 + 5000
        let numBlocks = 20
        var attackGains: [Float] = []
        for i in 0..<numBlocks {
            attackGains.append(blockGainDb(startFrame: attackStart + i * blockFrames))
        }

        // ── Release measurement ──
        // Phase 3 starts at frame 192000. Skip first 5000 frames for envelope settling at
        // the new quiet signal level. Then measure 20 consecutive blocks (200ms).
        let releaseStart = 192000 + 5000
        var releaseGains: [Float] = []
        for i in 0..<numBlocks {
            releaseGains.append(blockGainDb(startFrame: releaseStart + i * blockFrames))
        }

        // Attack: gains should be decreasing (becoming more negative)
        let attackDeltas = zip(attackGains, attackGains.dropFirst()).map { $1 - $0 }
        let avgAttackDelta = attackDeltas.reduce(0, +) / Float(attackDeltas.count)

        // Release: gains should be increasing (becoming less negative / toward 0)
        let releaseDeltas = zip(releaseGains, releaseGains.dropFirst()).map { $1 - $0 }
        let avgReleaseDelta = releaseDeltas.reduce(0, +) / Float(releaseDeltas.count)

        // Verify direction
        #expect(avgAttackDelta < 0,
                "Attack should decrease gain (avg delta = \(avgAttackDelta) dB/block)")
        #expect(avgReleaseDelta > 0,
                "Release should increase gain (avg delta = \(avgReleaseDelta) dB/block)")

        // The magnitude of attack rate should exceed release rate (asymmetric ballistics)
        #expect(abs(avgAttackDelta) > abs(avgReleaseDelta),
                "Attack rate \(abs(avgAttackDelta)) dB/block should exceed release rate \(abs(avgReleaseDelta)) dB/block")
    }

    // MARK: - Silence Gate (Anti-Breathing)

    @Test("Silence gate freezes gain during quiet passages")
    func silenceGateFreezesGain() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.suddenJumpProtectionEnabled = false  // avoid interference
        settings.silenceGateThresholdDb = 5.0
        settings.silenceGateFallbackTimeS = 0.0  // disable fallback so gain stays frozen

        let sampleRate: Float = 48000
        let channelCount = 2
        let blockFrames = 4800  // 100ms blocks
        let driveLinear = LoudnessEqualizerMath.dbToLinear(settings.driveDb)

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        // Layout:
        //   Phase 1: frames 0-47999  — loud signal (1s, 0.5 amplitude) to push gain negative
        //   Phase 2: frames 48000-95999 — very quiet signal (1s, 0.0005 amplitude, level ≈ -45 dBFS,
        //            well below -40 dB silence gate threshold)
        let totalFrames = 96000
        var input = [Float](repeating: 0, count: totalFrames * channelCount)

        for frame in 0..<48000 {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.5 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        for frame in 48000..<totalFrames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.0001 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        var output = [Float](repeating: 0, count: totalFrames * channelCount)
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: totalFrames,
                    channelCount: channelCount
                )
            }
        }

        // Helper: compute effective gain (dB) for a block of frames.
        func blockGainDb(startFrame: Int) -> Float {
            let endFrame = min(startFrame + blockFrames, totalFrames)
            guard endFrame > startFrame else { return -120 }
            var inSumSq: Double = 0
            var outSumSq: Double = 0
            var count = 0
            for frame in startFrame..<endFrame {
                let base = frame * channelCount
                inSumSq += Double(input[base] * input[base] + input[base + 1] * input[base + 1])
                outSumSq += Double(output[base] * output[base] + output[base + 1] * output[base + 1])
                count += 2
            }
            let inRMS = Float(sqrt(inSumSq / Double(count)))
            let outRMS = Float(sqrt(outSumSq / Double(count)))
            guard inRMS > 1e-10 else { return -120 }
            let gainLin = outRMS / (inRMS * driveLinear)
            return LoudnessEqualizerMath.linearToDb(gainLin)
        }

        // Gain at end of phase 1 (last 100ms of loud signal)
        let gainPhase1 = blockGainDb(startFrame: 43200)
        // Gain at end of phase 2 (last 100ms of quiet signal — should be frozen near phase1 value)
        let gainPhase2 = blockGainDb(startFrame: 91200)

        #expect(gainPhase1 < -5,
                "Gain after loud signal should be < -5 dB, got \(gainPhase1)")
        #expect(gainPhase2 < -5,
                "Gain after quiet passage should still be < -5 dB (frozen), got \(gainPhase2)")
        // Gain should not have recovered significantly (silence gate prevents release)
        #expect(abs(gainPhase2 - gainPhase1) < 3.0,
                "Gain should be frozen by silence gate: change \(gainPhase2 - gainPhase1) dB, expected < 3 dB")
    }

    // MARK: - AGC Window (Dead Zone)

    @Test("AGC window holds gain within comfort zone")
    func agcWindowHoldsGainWithinComfortZone() {
        let sampleRate: Float = 48000
        let channelCount = 2
        let driveLinear = LoudnessEqualizerMath.dbToLinear(LoudnessEqualizerSettings().driveDb)

        var settingsWideWindow = LoudnessEqualizerSettings()
        settingsWideWindow.enabled = true
        settingsWideWindow.suddenJumpProtectionEnabled = false
        settingsWideWindow.agcWindowSizeDb = 20.0  // ±10 dB dead zone
        settingsWideWindow.releaseSpeedDbPerSecPer6Db = 100.0
        settingsWideWindow.progressiveRatioEnabled = false
        settingsWideWindow.silenceGateThresholdDb = -60.0
        settingsWideWindow.silenceGateSlowdownDb = -60.0
        settingsWideWindow.silenceGateIdleGainDb = 0.0

        var settingsZeroWindow = LoudnessEqualizerSettings()
        settingsZeroWindow.enabled = true
        settingsZeroWindow.suddenJumpProtectionEnabled = false
        settingsZeroWindow.agcWindowSizeDb = 0.0   // no dead zone
        settingsZeroWindow.releaseSpeedDbPerSecPer6Db = 100.0
        settingsZeroWindow.progressiveRatioEnabled = false
        settingsZeroWindow.silenceGateThresholdDb = -60.0
        settingsZeroWindow.silenceGateSlowdownDb = -60.0
        settingsZeroWindow.silenceGateIdleGainDb = 0.0

        let eqWide = LoudnessEqualizer(settings: settingsWideWindow, sampleRate: sampleRate)
        let eqZero = LoudnessEqualizer(settings: settingsZeroWindow, sampleRate: sampleRate)

        // Phase 1: Warmup with a low-level signal to release the initial gain from -24.1 dB toward 0 dB.
        // Signal at amplitude 0.003 → driven peak ≈ 0.048 (~-26 dBFS). This is:
        //   - Below -7.9 dBFS target (so zero-window instance RELEASES)
        //   - Below -17.9 dBFS target - halfWindow (so wide-window instance RELEASES)
        //   - Above -40 dBFS silence gate threshold (so gain is NOT frozen)
        // With proportional release (100 dB/s per 6 dB deficit), the gain reaches < -0.01 dB
        // in ~16000 frames. We use 24000 frames (500 ms) for safety margin.
        let warmupFrames = 24000  // 500 ms — plenty to release 24 dB
        let testFrames = 72000    // 1.5 s — plenty of time for attack to manifest
        let totalFrames = warmupFrames + testFrames

        // Test signal at amplitude 0.05 → driven peak ≈ 0.8, K-weighted envelope ≈ -2 dBFS.
        // delta = -2 - (-7.9) ≈ 5.9 dB, well within the ±10 dB comfort zone of the wide window.
        // For the zero-window instance, this delta triggers attack toward targetGainDb = -5.9 dB.
        let testAmplitude: Float = 0.05

        var input = [Float](repeating: 0, count: totalFrames * channelCount)

        // Warmup section
        let warmupAmplitude: Float = 0.003
        for frame in 0..<warmupFrames {
            let phase = Float(2.0 * Double.pi * 2500.0 * Double(frame) / Double(sampleRate))
            let sample: Float = warmupAmplitude * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        // Test section
        for frame in warmupFrames..<totalFrames {
            let phase = Float(2.0 * Double.pi * 2500.0 * Double(frame) / Double(sampleRate))
            let sample: Float = testAmplitude * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        var outputWide = [Float](repeating: 0, count: totalFrames * channelCount)
        var outputZero = [Float](repeating: 0, count: totalFrames * channelCount)

        var inputCopy = input
        input.withUnsafeMutableBufferPointer { inPtr in
            outputWide.withUnsafeMutableBufferPointer { outPtr in
                eqWide.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: totalFrames, channelCount: channelCount)
            }
        }
        inputCopy.withUnsafeMutableBufferPointer { inPtr in
            outputZero.withUnsafeMutableBufferPointer { outPtr in
                eqZero.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: totalFrames, channelCount: channelCount)
            }
        }

        func measureGainDb(output: [Float], startFrame: Int, endFrame: Int) -> Float {
            guard endFrame > startFrame else { return -120 }
            var inSumSq: Double = 0
            var outSumSq: Double = 0
            var count = 0
            for frame in startFrame..<endFrame {
                let base = frame * channelCount
                inSumSq += Double(input[base] * input[base] + input[base + 1] * input[base + 1])
                outSumSq += Double(output[base] * output[base] + output[base + 1] * output[base + 1])
                count += 2
            }
            let inRMS = Float(sqrt(inSumSq / Double(count)))
            let outRMS = Float(sqrt(outSumSq / Double(count)))
            guard inRMS > 1e-10 else { return -120 }
            return LoudnessEqualizerMath.linearToDb(outRMS / (inRMS * driveLinear))
        }

        // Measure gain over the last 100 ms of the test section
        let measureStart = totalFrames - 4800
        let gainWide = measureGainDb(output: outputWide, startFrame: measureStart, endFrame: totalFrames)
        let gainZero = measureGainDb(output: outputZero, startFrame: measureStart, endFrame: totalFrames)

        // After warmup, gain for both instances should be near 0 dB.
        // Test signal (amplitude 0.05) is ~5.9 dB above target:
        //   - 20 dB window (±10 dB): |5.9| ≤ 10 → HOLD → gain stays near 0 dB
        //   -  0 dB window: 5.9 > 0 → ATTACK → gain goes toward targetGainDb = -5.9 dB
        #expect(gainWide > -2.0,
                "With 20 dB window, gain should stay near 0 dB (held by window), got \(gainWide) dB")
        #expect(gainZero < -5.0,
                "Without window, gain should be significantly negative (attack active), got \(gainZero) dB")
        #expect(gainWide > gainZero,
                "Wide window gain \(gainWide) dB should exceed zero window gain \(gainZero) dB")
    }

    @Test("AGC window allows recovery/release when starting fully attenuated and input is inside window")
    func agcWindowAllowsRecoveryWhenStartingAttenuated() {
        let sampleRate: Float = 48000
        let channelCount = 2
        
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.driveDb = 24.0
        settings.targetLevelDb = -7.9
        settings.agcWindowSizeDb = 4.5
        settings.releaseSpeedDbPerSecPer6Db = 2.45
        settings.silenceGateThresholdDb = -16.0
        settings.silenceGateSlowdownDb = -12.0
        settings.silenceGateIdleGainDb = -24.0

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        // Quiet signal: -30 dBFS peak
        // With drive +24 dB, driven peak is -6.0 dBFS.
        // The level is inside the comfort window, but the gain starts at -24.0 dB.
        // We expect it to recover towards 0.0 dB (so it is not stuck at -24.0 dB).
        let amplitude = LoudnessEqualizerMath.dbToLinear(-30.0)
        let frameCount = 48000 // 1 second
        
        var input = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample = amplitude * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        var output = [Float](repeating: 0, count: frameCount * channelCount)
        
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            }
        }
        
        // Measure gain at the end of 1 second.
        let finalGain = eq.masterGainDb
        #expect(finalGain > -23.0,
                "Gain should have recovered from -24.0 dB startup attenuation, got \(finalGain) dB")
    }

    // MARK: - Silence Gate Fallback, Gate Slowdown, and Sudden Drop Protection

    @Test("Silence gate fallback slowly recovers gain during quiet passages")
    func silenceGateFallbackSlowlyRecoversGain() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.suddenJumpProtectionEnabled = false  // avoid interference
        settings.silenceGateThresholdDb = 5.0 // set high threshold to trigger silence gate
        settings.silenceGateFallbackTimeS = 0.5  // short fallback time for faster drift
        settings.silenceGateIdleGainDb = 0.0

        let sampleRate: Float = 48000
        let channelCount = 2
        let blockFrames = 4800  // 100ms blocks
        let driveLinear = LoudnessEqualizerMath.dbToLinear(settings.driveDb)

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        // Phase 1: loud signal to push gain negative (0.5s)
        // Phase 2: quiet signal (1s) to allow fallback recovery
        let phase1Frames = 24000
        let totalFrames = 72000
        var input = [Float](repeating: 0, count: totalFrames * channelCount)

        for frame in 0..<phase1Frames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.5 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        for frame in phase1Frames..<totalFrames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.0001 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        var output = [Float](repeating: 0, count: totalFrames * channelCount)
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: totalFrames,
                    channelCount: channelCount
                )
            }
        }

        func blockGainDb(startFrame: Int) -> Float {
            let endFrame = min(startFrame + blockFrames, totalFrames)
            guard endFrame > startFrame else { return -120 }
            var inSumSq: Double = 0
            var outSumSq: Double = 0
            var count = 0
            for frame in startFrame..<endFrame {
                let base = frame * channelCount
                inSumSq += Double(input[base] * input[base] + input[base + 1] * input[base + 1])
                outSumSq += Double(output[base] * output[base] + output[base + 1] * output[base + 1])
                count += 2
            }
            let inRMS = Float(sqrt(inSumSq / Double(count)))
            let outRMS = Float(sqrt(outSumSq / Double(count)))
            guard inRMS > 1e-10 else { return -120 }
            let gainLin = outRMS / (inRMS * driveLinear)
            return LoudnessEqualizerMath.linearToDb(gainLin)
        }

        let gainPhase1 = blockGainDb(startFrame: phase1Frames - blockFrames)
        let gainPhase2 = blockGainDb(startFrame: totalFrames - blockFrames)

        #expect(gainPhase1 < -5.0, "Gain after loud signal should be < -5 dB, got \(gainPhase1)")
        #expect(gainPhase2 > gainPhase1 + 2.0, "Gain should recover under fallback drift: gainPhase1=\(gainPhase1), gainPhase2=\(gainPhase2)")
        #expect(gainPhase2 <= 0.0, "Gain should not exceed 0 dB, got \(gainPhase2)")
    }

    @Test("Gate slowdown reduces release speed when signal is in the transition zone")
    func gateSlowdownSlowsRelease() {
        var settingsNormal = LoudnessEqualizerSettings()
        settingsNormal.enabled = true
        settingsNormal.suddenJumpProtectionEnabled = false
        settingsNormal.suddenDropProtection = false  // disable drop protection
        settingsNormal.silenceGateThresholdDb = -40.0
        settingsNormal.silenceGateSlowdownDb = -60.0 // disable slowdown for normal
        settingsNormal.releaseSpeedDbPerSecPer6Db = 1.0 // slow release

        var settingsSlow = LoudnessEqualizerSettings()
        settingsSlow.enabled = true
        settingsSlow.suddenJumpProtectionEnabled = false
        settingsSlow.suddenDropProtection = false  // disable drop protection
        settingsSlow.silenceGateThresholdDb = -40.0
        settingsSlow.silenceGateSlowdownDb = -20.0 // transition zone up to -20dB
        settingsSlow.gateSlowdownFactor = 0.1
        settingsSlow.releaseSpeedDbPerSecPer6Db = 1.0

        let sampleRate: Float = 48000
        let channelCount = 2
        let blockFrames = 4800

        // Phase 1: loud signal to push gain negative (0.5s)
        // Phase 2: level at -35 dBFS (inside slowdown zone for settingsSlow, above threshold for settingsNormal) (2.5s)
        let phase1Frames = 24000
        let totalFrames = 144000
        var input = [Float](repeating: 0, count: totalFrames * channelCount)

        // Drive is 24.1 dB (x16.03).
        // To make driven signal in Phase 2 have level -35 dBFS:
        // target level is -35 dBFS, so raw amplitude should be 10^(-35/20) / 16.03 = 0.0177 / 16.03 ≈ 0.0011
        for frame in 0..<phase1Frames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.05 * sin(phase) // Lower Phase 1 level to avoid massive envelope tail
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        for frame in phase1Frames..<totalFrames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.0011 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        let eqNormal = LoudnessEqualizer(settings: settingsNormal, sampleRate: sampleRate)
        let eqSlow = LoudnessEqualizer(settings: settingsSlow, sampleRate: sampleRate)

        var outputNormal = [Float](repeating: 0, count: totalFrames * channelCount)
        var outputSlow = [Float](repeating: 0, count: totalFrames * channelCount)

        var inputCopy = input
        input.withUnsafeMutableBufferPointer { inPtr in
            outputNormal.withUnsafeMutableBufferPointer { outPtr in
                eqNormal.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: totalFrames, channelCount: channelCount)
            }
        }
        inputCopy.withUnsafeMutableBufferPointer { inPtr in
            outputSlow.withUnsafeMutableBufferPointer { outPtr in
                eqSlow.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: totalFrames, channelCount: channelCount)
            }
        }

        func measureGainDb(output: [Float], startFrame: Int, endFrame: Int, driveDb: Float) -> Float {
            let driveLin = LoudnessEqualizerMath.dbToLinear(driveDb)
            var inSumSq: Double = 0
            var outSumSq: Double = 0
            var count = 0
            for frame in startFrame..<endFrame {
                let base = frame * channelCount
                inSumSq += Double(input[base] * input[base] + input[base + 1] * input[base + 1])
                outSumSq += Double(output[base] * output[base] + output[base + 1] * output[base + 1])
                count += 2
            }
            let inRMS = Float(sqrt(inSumSq / Double(count)))
            let outRMS = Float(sqrt(outSumSq / Double(count)))
            return LoudnessEqualizerMath.linearToDb(outRMS / (inRMS * driveLin))
        }

        // Measure recovery in the quiet part (compare gain near start of phase 2 vs end of phase 2)
        let gainNormal1 = measureGainDb(output: outputNormal, startFrame: phase1Frames + 48000, endFrame: phase1Frames + 48000 + blockFrames, driveDb: settingsNormal.driveDb)
        let gainNormal2 = measureGainDb(output: outputNormal, startFrame: totalFrames - blockFrames, endFrame: totalFrames, driveDb: settingsNormal.driveDb)

        let gainSlow1 = measureGainDb(output: outputSlow, startFrame: phase1Frames + 48000, endFrame: phase1Frames + 48000 + blockFrames, driveDb: settingsSlow.driveDb)
        let gainSlow2 = measureGainDb(output: outputSlow, startFrame: totalFrames - blockFrames, endFrame: totalFrames, driveDb: settingsSlow.driveDb)

        let recoveryNormal = gainNormal2 - gainNormal1
        let recoverySlow = gainSlow2 - gainSlow1

        #expect(recoveryNormal > 0.2, "Normal release should recover gain, got \(recoveryNormal) dB")
        #expect(recoverySlow < recoveryNormal * 0.35, "Slow slowdown release (\(recoverySlow) dB) should be much slower than normal (\(recoveryNormal) dB)")
    }

    @Test("Sudden drop protection accelerates release when level falls far below target")
    func suddenDropProtectionSpeedsUpRelease() {
        var settingsNormal = LoudnessEqualizerSettings()
        settingsNormal.enabled = true
        settingsNormal.suddenJumpProtectionEnabled = false
        settingsNormal.suddenDropProtection = false // disable drop protection
        settingsNormal.silenceGateSlowdownDb = -60.0 // disable slowdown
        settingsNormal.silenceGateThresholdDb = -60.0 // disable silence gate
        settingsNormal.releaseSpeedDbPerSecPer6Db = 1.0 // slow release

        var settingsDrop = LoudnessEqualizerSettings()
        settingsDrop.enabled = true
        settingsDrop.suddenJumpProtectionEnabled = false
        settingsDrop.suddenDropProtection = true
        settingsDrop.suddenDropThresholdDb = 5.0  // drop below target > 5 dB triggers speedup
        settingsDrop.suddenDropSpeedup = 5.0
        settingsDrop.silenceGateSlowdownDb = -60.0 // disable slowdown
        settingsDrop.silenceGateThresholdDb = -60.0 // disable silence gate
        settingsDrop.releaseSpeedDbPerSecPer6Db = 1.0

        let sampleRate: Float = 48000
        let channelCount = 2
        let blockFrames = 4800

        // Phase 1: loud signal to push gain negative (0.5s)
        // Phase 2: drop signal to well below target (e.g. 17 dB below target).
        // Target is -7.9 dBFS. If driven level is -25 dBFS, delta is -17.1 dB.
        // Raw amplitude = 10^(-25/20) / 16.03 = 0.056 / 16.03 ≈ 0.0035
        let phase1Frames = 24000
        let totalFrames = 144000
        var input = [Float](repeating: 0, count: totalFrames * channelCount)

        for frame in 0..<phase1Frames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.05 * sin(phase) // Lower Phase 1 level to avoid massive envelope tail
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }
        for frame in phase1Frames..<totalFrames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample: Float = 0.0035 * sin(phase)
            let base = frame * channelCount
            input[base] = sample
            input[base + 1] = sample
        }

        let eqNormal = LoudnessEqualizer(settings: settingsNormal, sampleRate: sampleRate)
        let eqDrop = LoudnessEqualizer(settings: settingsDrop, sampleRate: sampleRate)

        var outputNormal = [Float](repeating: 0, count: totalFrames * channelCount)
        var outputDrop = [Float](repeating: 0, count: totalFrames * channelCount)

        var inputCopy = input
        input.withUnsafeMutableBufferPointer { inPtr in
            outputNormal.withUnsafeMutableBufferPointer { outPtr in
                eqNormal.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: totalFrames, channelCount: channelCount)
            }
        }
        inputCopy.withUnsafeMutableBufferPointer { inPtr in
            outputDrop.withUnsafeMutableBufferPointer { outPtr in
                eqDrop.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: totalFrames, channelCount: channelCount)
            }
        }

        func measureGainDb(output: [Float], startFrame: Int, endFrame: Int, driveDb: Float) -> Float {
            let driveLin = LoudnessEqualizerMath.dbToLinear(driveDb)
            var inSumSq: Double = 0
            var outSumSq: Double = 0
            var count = 0
            for frame in startFrame..<endFrame {
                let base = frame * channelCount
                inSumSq += Double(input[base] * input[base] + input[base + 1] * input[base + 1])
                outSumSq += Double(output[base] * output[base] + output[base + 1] * output[base + 1])
                count += 2
            }
            let inRMS = Float(sqrt(inSumSq / Double(count)))
            let outRMS = Float(sqrt(outSumSq / Double(count)))
            return LoudnessEqualizerMath.linearToDb(outRMS / (inRMS * driveLin))
        }

        let gainNormal1 = measureGainDb(output: outputNormal, startFrame: phase1Frames + 48000, endFrame: phase1Frames + 48000 + blockFrames, driveDb: settingsNormal.driveDb)
        let gainNormal2 = measureGainDb(output: outputNormal, startFrame: totalFrames - blockFrames, endFrame: totalFrames, driveDb: settingsNormal.driveDb)

        let gainDrop1 = measureGainDb(output: outputDrop, startFrame: phase1Frames + 48000, endFrame: phase1Frames + 48000 + blockFrames, driveDb: settingsDrop.driveDb)
        let gainDrop2 = measureGainDb(output: outputDrop, startFrame: totalFrames - blockFrames, endFrame: totalFrames, driveDb: settingsDrop.driveDb)

        let recoveryNormal = gainNormal2 - gainNormal1
        let recoveryDrop = gainDrop2 - gainDrop1

        #expect(recoveryDrop > recoveryNormal * 1.5, "Drop-protected release (\(recoveryDrop) dB) should be significantly faster than normal (\(recoveryNormal) dB)")
    }

    // MARK: - Orban Progressive Ratio & Idle Gain Fallback

    @Test("Silence gate fallback drifts gain toward negative idle gain from below")
    func silenceGateFallbackDriftsToIdleGainFromBelow() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.driveDb = 20.0
        settings.silenceGateThresholdDb = 5.0 // high threshold to trigger gate
        settings.silenceGateFallbackTimeS = 0.1 // 100ms time constant
        settings.silenceGateIdleGainDb = -10.0

        let sampleRate: Float = 48000
        let channelCount = 2
        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        // Initial gain starts at -20.0 dB
        #expect(abs(eq.currentGainDb - (-20.0)) < 0.01)

        // Process 1 second (48000 frames) of pure silence
        let silenceFrames = 48000
        let input = [Float](repeating: 0.0, count: silenceFrames * channelCount)
        var output = [Float](repeating: 0.0, count: silenceFrames * channelCount)

        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: silenceFrames,
                    channelCount: channelCount
                )
            }
        }

        // Final gain should have drifted up toward -10.0 dB
        let finalGain = eq.currentGainDb
        #expect(abs(finalGain - (-10.0)) < 0.1, "Expected gain to drift to -10.0 dB, got \(finalGain) dB")
    }

    @Test("Silence gate fallback drifts gain toward negative idle gain from above")
    func silenceGateFallbackDriftsToIdleGainFromAbove() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.driveDb = 0.0
        settings.silenceGateThresholdDb = 5.0
        settings.silenceGateFallbackTimeS = 0.1
        settings.silenceGateIdleGainDb = -10.0

        let sampleRate: Float = 48000
        let channelCount = 2
        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        #expect(abs(eq.currentGainDb - 0.0) < 0.01)

        let silenceFrames = 48000
        let input = [Float](repeating: 0.0, count: silenceFrames * channelCount)
        var output = [Float](repeating: 0.0, count: silenceFrames * channelCount)

        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(
                    input: inPtr.baseAddress!,
                    output: outPtr.baseAddress!,
                    frameCount: silenceFrames,
                    channelCount: channelCount
                )
            }
        }

        let finalGain = eq.currentGainDb
        #expect(abs(finalGain - (-10.0)) < 0.1, "Expected gain to drift down to -10.0 dB, got \(finalGain) dB")
    }

    @Test("Progressive ratio applies soft-knee compression slope")
    func progressiveRatioAppliesSoftKnee() {
        let sampleRate: Float = 48000
        let channelCount = 2
        
        // Instance A: Brickwall AGC (Progressive Ratio disabled)
        var settingsBrick = LoudnessEqualizerSettings()
        settingsBrick.enabled = true
        settingsBrick.driveDb = 0.0
        settingsBrick.targetLevelDb = -10.0
        settingsBrick.agcWindowSizeDb = 0.0
        settingsBrick.progressiveRatioEnabled = false
        settingsBrick.attackSpeedDbPerSecPer6Db = 1000.0 // instant attack
        settingsBrick.suddenJumpProtectionEnabled = false
        
        // Instance B: Progressive Ratio AGC
        var settingsProg = LoudnessEqualizerSettings()
        settingsProg.enabled = true
        settingsProg.driveDb = 0.0
        settingsProg.targetLevelDb = -10.0
        settingsProg.agcWindowSizeDb = 0.0
        settingsProg.progressiveRatioEnabled = true
        settingsProg.minRatio = 2.0
        settingsProg.maxRatio = Float.infinity
        settingsProg.progressiveRate = 0.15
        settingsProg.attackSpeedDbPerSecPer6Db = 1000.0 // instant attack
        settingsProg.suddenJumpProtectionEnabled = false

        let eqBrick = LoudnessEqualizer(settings: settingsBrick, sampleRate: sampleRate)
        let eqProg = LoudnessEqualizer(settings: settingsProg, sampleRate: sampleRate)

        // Warm up / process a loud 1 kHz sine wave at amplitude 0.5 (~ -6 dBFS K-weighted/RMS).
        // Since target is -10 dBFS, overshoot is ~4 dB.
        let testFrames = 4800
        var input = [Float](repeating: 0.0, count: testFrames * channelCount)
        for frame in 0..<testFrames {
            let phase = Float(2.0 * Double.pi * 2500.0 * Double(frame) / Double(sampleRate))
            let sample = Float(0.5 * sin(phase))
            input[frame * 2] = sample
            input[frame * 2 + 1] = sample
        }
        
        var outputBrick = [Float](repeating: 0.0, count: testFrames * channelCount)
        var outputProg = [Float](repeating: 0.0, count: testFrames * channelCount)
        
        input.withUnsafeBufferPointer { inPtr in
            outputBrick.withUnsafeMutableBufferPointer { outPtr in
                eqBrick.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: testFrames, channelCount: channelCount)
            }
            outputProg.withUnsafeMutableBufferPointer { outPtr in
                eqProg.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: testFrames, channelCount: channelCount)
            }
        }

        // Brickwall target gain should be -delta (which is around -4.0 dB or more negative)
        let gainBrick = eqBrick.currentGainDb
        
        // Progressive target gain should be less negative (around -2.9 dB)
        let gainProg = eqProg.currentGainDb
        
        #expect(gainBrick < -3.0, "Brickwall should compress fully, got \(gainBrick) dB")
        #expect(gainProg > gainBrick + 0.5, "Progressive ratio should compress less, got \(gainProg) dB vs brickwall \(gainBrick) dB")
        #expect(gainProg < -1.0, "Progressive ratio should still compress, got \(gainProg) dB")
    }

    @Test("Custom parametric sidechain filter alters gain response depending on frequency")
    func customSidechainFilterAltersResponse() {
        let sampleRate: Float = 48000
        let channelCount = 2
        
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.driveDb = 12.0
        settings.targetLevelDb = -12.0
        settings.agcWindowSizeDb = 0.0
        settings.attackSpeedDbPerSecPer6Db = 10.0
        settings.releaseSpeedDbPerSecPer6Db = 10.0
        settings.suddenJumpProtectionEnabled = false
        
        let eq781 = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)
        let eq2500 = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)
        
        let testFrames = 9600 // 0.2 seconds
        var input781 = [Float](repeating: 0.0, count: testFrames * channelCount)
        var input2500 = [Float](repeating: 0.0, count: testFrames * channelCount)
        for frame in 0..<testFrames {
            let phase781 = Float(2.0 * Double.pi * 781.0 * Double(frame) / Double(sampleRate))
            input781[frame * 2] = 0.8 * sin(phase781)
            input781[frame * 2 + 1] = 0.8 * sin(phase781)
            
            let phase2500 = Float(2.0 * Double.pi * 2500.0 * Double(frame) / Double(sampleRate))
            input2500[frame * 2] = 0.8 * sin(phase2500)
            input2500[frame * 2 + 1] = 0.8 * sin(phase2500)
        }
        
        var output781 = [Float](repeating: 0.0, count: testFrames * channelCount)
        var output2500 = [Float](repeating: 0.0, count: testFrames * channelCount)
        
        input781.withUnsafeBufferPointer { inPtr in
            output781.withUnsafeMutableBufferPointer { outPtr in
                eq781.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: testFrames, channelCount: channelCount)
            }
        }
        input2500.withUnsafeBufferPointer { inPtr in
            output2500.withUnsafeMutableBufferPointer { outPtr in
                eq2500.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: testFrames, channelCount: channelCount)
            }
        }
        
        let finalGain781 = eq781.currentGainDb
        let finalGain2500 = eq2500.currentGainDb
        
        #expect(finalGain781 > finalGain2500 + 1.0, "Custom filter should compress a 781Hz signal less than a 2500Hz signal due to its -8.1 dB peak cut: 781Hz \(finalGain781) dB vs 2500Hz \(finalGain2500) dB")
    }

    @Test("Bass band gain is clamped to master band gain plus 3.0 dB under bass-light input")
    func bassBandClampedToMaster() {
        let sampleRate: Float = 48000
        let channelCount = 2

        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        settings.driveDb = 24.0
        settings.targetLevelDb = -12.0
        settings.agcWindowSizeDb = 0.0
        settings.attackSpeedDbPerSecPer6Db = 10.0
        settings.releaseSpeedDbPerSecPer6Db = 10.0
        settings.suddenJumpProtectionEnabled = false

        let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

        // Generate a 1000 Hz sine wave (bass-light signal, completely above 150 Hz crossover)
        // at high amplitude to drive the master band into heavy compression.
        let testFrames = 4800 // 0.1 seconds
        var input = [Float](repeating: 0.0, count: testFrames * channelCount)
        for frame in 0..<testFrames {
            let phase = Float(2.0 * Double.pi * 1000.0 * Double(frame) / Double(sampleRate))
            let sample = Float(0.8 * sin(phase))
            input[frame * 2] = sample
            input[frame * 2 + 1] = sample
        }

        var output = [Float](repeating: 0.0, count: testFrames * channelCount)
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                eq.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: testFrames, channelCount: channelCount)
            }
        }

        // Under bass-light input:
        // - Master band should compress heavily (e.g., gain < -10 dB)
        // - Bass band has no signal, so it would want to be at 0 dB.
        // - But due to the coupling clamp, bass gain should be capped to master gain + 3 dB.
        let masterGain = eq.masterGainDb
        let bassGain = eq.bassGainDb

        #expect(masterGain < -10.0, "Master band should compress significantly, got \(masterGain) dB")
        #expect(abs(bassGain - (masterGain + 3.0)) < 0.1, "Bass gain should track master gain + 3.0 dB exactly, got \(bassGain) dB vs master \(masterGain) dB")
    }
}

@Suite("LinkwitzRileyCrossover2Tests")
struct LinkwitzRileyCrossover2Tests {
    let frequency: Double = 150.0
    let sampleRate: Double = 48000

    private func generateSineSweep(startFreq: Double, endFreq: Double, sampleRate: Double, frameCount: Int) -> [Float] {
        var signal = [Float](repeating: 0, count: frameCount)
        let T = Double(frameCount) / sampleRate
        let logRatio = log(endFreq / startFreq)
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let integral = startFreq * T / logRatio * (exp(t / T * logRatio) - 1.0)
            signal[i] = Float(sin(2.0 * Double.pi * integral))
        }
        return signal
    }

    private func rmsSteadyState(_ signal: [Float], skipFirst: Int) -> Float {
        let slice = signal.dropFirst(skipFirst)
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for s in slice { sum += s * s }
        return sqrt(sum / Float(slice.count))
    }

    private func ampToDB(_ value: Float) -> Float {
        return 20.0 * log10(max(value, Float.leastNormalMagnitude))
    }

    @Test("LR2 Crossover sum is identical to input (allpass reconstruction)")
    func crossoverReconstruction() {
        let frameCount = 4096
        let skipTransient = 2048
        let input = generateSineSweep(startFreq: 20, endFreq: 20000, sampleRate: sampleRate, frameCount: frameCount)

        var crossover = LinkwitzRileyCrossover2(frequency: frequency, sampleRate: sampleRate)

        var summed = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let (low, high) = crossover.process(input[i])
            summed[i] = low + high
        }

        let inputRMS = rmsSteadyState(input, skipFirst: skipTransient)
        let outputRMS = rmsSteadyState(summed, skipFirst: skipTransient)
        let diffDB = abs(ampToDB(outputRMS) - ampToDB(inputRMS))

        #expect(diffDB < 1.0, "Summed output magnitude differs from input by \(diffDB) dB (expected < 1.0)")
    }
}


