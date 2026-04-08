// FineTuneTests/LoudnessEqualizerTests.swift
// Unit tests for the LoudnessEqualizer feature.

import Testing
import Foundation
@testable import FineTune

@Suite("LoudnessEqualizer")
struct LoudnessEqualizerTests {

    // MARK: - LoudnessEqualizerSettings

    @Test("Settings default to approved MVP values")
    func settingsDefaults() {
        let s = LoudnessEqualizerSettings()
        #expect(s.targetLoudnessDb == -12)
        #expect(s.maxBoostDb == 15)
        #expect(s.maxCutDb == 4)
        #expect(s.compressionThresholdOffsetDb == 6)
        #expect(s.compressionRatio == 1.6)
        #expect(s.compressionKneeDb == 8)
        #expect(s.analysisWindowMs == 30)
        #expect(s.analysisHopMs == 15)
        #expect(s.detectorAttackMs == 25)
        #expect(s.detectorReleaseMs == 400)
        #expect(s.gainAttackMs == 180)
        #expect(s.gainReleaseMs == 5000)
        #expect(s.noiseFloorThresholdDb == -48)
        #expect(s.lowLevelMaxBoostDb == 1.5)
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

    // MARK: - LoudnessDetector

    @Test("Detector attack responds faster than release")
    func detectorAttackFasterThanRelease() {
        var settings = LoudnessEqualizerSettings()
        settings.detectorAttackMs = 15
        settings.detectorReleaseMs = 120
        let sampleRate: Float = 48000
        let detector = LoudnessDetector(settings: settings, sampleRate: sampleRate)

        // Start from a known level
        let startDb: Float = -30
        // Simulate attack: jump up by 20 dB
        let highDb: Float = -10
        // Simulate release: drop back down
        let lowDb: Float = -30

        // Drive envelope up for a few steps
        var attackLevel: Float = startDb
        for _ in 0..<5 {
            attackLevel = detector.updateEnvelope(with: highDb)
        }

        // Reset and drive envelope down for same number of steps from high
        detector.reset()
        // Seed at high level first
        for _ in 0..<20 {
            _ = detector.updateEnvelope(with: highDb)
        }
        var releaseLevel: Float = highDb
        for _ in 0..<5 {
            releaseLevel = detector.updateEnvelope(with: lowDb)
        }

        // After 5 attack steps from -30 toward -10, level should be closer to -10
        // After 5 release steps from -10 toward -30, level should still be closer to -10
        // So the attack gain (distance covered) should be larger than the release gain
        let attackGain = attackLevel - startDb   // positive: moved up
        let releaseGain = highDb - releaseLevel  // positive: moved down

        #expect(attackGain > releaseGain,
                "Attack moved \(attackGain) dB in 5 steps; release moved \(releaseGain) dB — attack should be faster")
    }

    // MARK: - GainComputer

    @Test("Gain computer boosts quiet material and softly cuts louder material")
    func gainComputerClamps() {
        var settings = LoudnessEqualizerSettings()
        settings.targetLoudnessDb = -12
        settings.maxBoostDb = 4
        settings.maxCutDb = 6
        settings.compressionThresholdOffsetDb = 4
        settings.compressionRatio = 1.5
        settings.compressionKneeDb = 6
        settings.noiseFloorThresholdDb = -80 // disable noise floor for this test
        let computer = GainComputer(settings: settings)

        let quietSignal = computer.desiredGainDb(forLevelDb: -18)
        #expect(quietSignal == settings.maxBoostDb, "Quiet signals should still boost toward target")

        let withinKnee = computer.desiredGainDb(forLevelDb: -10)
        #expect(withinKnee < 0, "Signals inside the soft knee should get a small cut")
        #expect(withinKnee > -1.5, "Soft-knee cut should stay gentle near the threshold")

        let loudSignal = computer.desiredGainDb(forLevelDb: 12)
        #expect(loudSignal == -settings.maxCutDb, "Very loud signals should clamp to maxCutDb")
    }

    @Test("Gain computer limits boost below noise floor threshold")
    func gainComputerNoiseFloorProtection() {
        var settings = LoudnessEqualizerSettings()
        settings.targetLoudnessDb = -20
        settings.maxBoostDb = 10
        settings.noiseFloorThresholdDb = -55
        settings.lowLevelMaxBoostDb = 4
        let computer = GainComputer(settings: settings)

        // Signal well below the noise floor threshold should have boost limited to lowLevelMaxBoostDb
        let gainAtNoise = computer.desiredGainDb(forLevelDb: -70)
        #expect(gainAtNoise <= settings.lowLevelMaxBoostDb, "Boost near noise floor should be capped at lowLevelMaxBoostDb")
    }

    // MARK: - GainSmoother

    @Test("Gain smoother reduces gain faster than it recovers")
    func gainSmootherAsymmetry() {
        var settings = LoudnessEqualizerSettings()
        settings.gainAttackMs = 30    // fast reduction (attack toward lower gain)
        settings.gainReleaseMs = 700  // slow recovery (release toward higher gain)
        let smoother = GainSmoother(settings: settings, sampleRate: 48000)

        // Seed smoother at 0 dB
        smoother.reset(initialGainDb: 0)

        // Attack: target is -10 dB (reduction)
        var attackLevel: Float = 0
        for _ in 0..<10 {
            attackLevel = smoother.process(targetGainDb: -10)
        }

        // Reset and seed at -10 dB, then release toward 0 dB
        smoother.reset(initialGainDb: -10)
        var releaseLevel: Float = -10
        for _ in 0..<10 {
            releaseLevel = smoother.process(targetGainDb: 0)
        }

        // In 10 steps the gain reduction (attack) should cover more distance than recovery (release)
        let attackDistance = abs(attackLevel - 0)      // how far from 0 dB after attack steps
        let releaseDistance = abs(releaseLevel - (-10)) // how far from -10 dB after release steps

        #expect(releaseDistance < attackDistance,
                "Gain smoother should recover (\(releaseDistance) dB) slower than it reduces (\(attackDistance) dB)")
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

        // Verify L/R ratio is preserved within 1% tolerance
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
}
