// FineTuneTests/OutputGateTests.swift
//
// Pure-value tests for ProcessTapController.advanceOutputGate. Phase encoding:
// 0 = armed (muted), 1 = ramping (half-cosine fade-in), 2 = open.

import Testing
import Foundation
@testable import FineTune

// MARK: - Constants used across the suites

private let silenceThreshold: Float = 0.0001
private let belowThreshold: Float = 0.00005  // ½ of threshold → silent
private let aboveThreshold: Float = 0.01     // 100× threshold → non-silent
private let defaultRampSamples: Float = 1920          // 40 ms @ 48 kHz
private let defaultSilenceHold: Int32 = 9600          // 200 ms @ 48 kHz
private let cosineTolerance: Float = 1e-5

// MARK: - Armed phase

@Suite("OutputGate — armed phase (0)")
struct OutputGateArmedTests {

    @Test("Armed + silent input stays armed, returns 0, no state change")
    func armedAndSilentStaysArmed() {
        var phase: UInt8 = 0
        var progress: Float = 0
        var silent: Int32 = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: belowThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )

        #expect(mult == 0)
        #expect(phase == 0)
        #expect(progress == 0)
        #expect(silent == 0)
    }

    @Test("Armed + non-silent input enters ramping; entry buffer outputs 0")
    func armedAndNonSilentEntersRamping() {
        // Per the implementation: armed→ramping resets progress to 0 and
        // returns 0 immediately. The FIRST audible ramp output is the NEXT buffer.
        var phase: UInt8 = 0
        var progress: Float = 0.5      // garbage prior value
        var silent: Int32 = 12345      // garbage prior value

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: aboveThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )

        #expect(mult == 0)
        #expect(phase == 1, "armed→ramping transition")
        #expect(progress == 0, "progress reset on entry to ramping")
        #expect(silent == 0, "silentSamples cleared on entry to ramping")
    }

    @Test("Boundary: peak exactly == threshold is treated as silent (uses <=)")
    func peakEqualToThresholdIsSilent() {
        var phase: UInt8 = 0
        var progress: Float = 0
        var silent: Int32 = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: silenceThreshold,  // == 0.0001
            frameCount: 512,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )

        #expect(mult == 0)
        #expect(phase == 0, "peak == threshold must NOT trigger ramping")
    }
}

// MARK: - Ramping phase

@Suite("OutputGate — ramping phase (1)")
struct OutputGateRampingTests {

    @Test("Progress advances by frameCount/rampSamples per call, clamped to 1.0",
          arguments: [256, 512, 1024])
    func progressAdvancesLinearlyPerCall(frameCount: Int) {
        // Start in ramping with progress=0, then issue a single non-silent buffer.
        var phase: UInt8 = 1
        var progress: Float = 0
        var silent: Int32 = 0

        let delta = Float(frameCount) / defaultRampSamples
        // After 1 call, progress should be delta (assuming delta < 1.0).
        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: aboveThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )
        #expect(abs(progress - delta) < 1e-6, "expected progress=\(delta), got \(progress)")
        #expect(phase == 1)

        // After a 2nd call, progress = min(1.0, 2*delta). For frameCount=1024 with
        // rampSamples=1920, 2*delta = 1.067 → clamped to 1.0 and phase promotes to open.
        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: aboveThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )
        let expectedProgress = min(Float(1.0), 2 * delta)
        #expect(abs(progress - expectedProgress) < 1e-6, "expected progress=\(expectedProgress), got \(progress)")
        // Phase is still ramping if we haven't hit the clamp; open if we have.
        let expectedPhase: UInt8 = (2 * delta >= 1.0) ? 2 : 1
        #expect(phase == expectedPhase)
    }

    @Test("Ramping → open at progress >= 1.0; last ramping output ∈ [0,1), open output == 1.0")
    func rampingReachesOpenAtProgressOne() {
        var phase: UInt8 = 1
        var progress: Float = 0
        var silent: Int32 = 0
        let frameCount = 256
        let stepsToOpen = Int((defaultRampSamples / Float(frameCount)).rounded(.up))  // 8 calls

        var lastRampingOutput: Float = -1
        var openOutput: Float = -1
        var promotionStep: Int = -1

        for step in 1...(stepsToOpen + 1) {
            let mult = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                silentSamples: &silent,
                maxPeak: aboveThreshold,
                frameCount: frameCount,
                rampSamples: defaultRampSamples,
                silenceHoldSamples: defaultSilenceHold
            )
            if phase == 2 && promotionStep < 0 {
                promotionStep = step
                openOutput = mult
            } else if phase == 1 {
                lastRampingOutput = mult
            }
        }

        #expect(promotionStep > 0, "ramping must transition to open within stepsToOpen+1 calls")
        #expect(lastRampingOutput >= 0 && lastRampingOutput < 1.0,
                "last ramping output should be in [0, 1), got \(lastRampingOutput)")
        #expect(openOutput == 1.0, "promotion-call output should be exactly 1.0")
        #expect(phase == 2)
    }

    @Test("Half-cosine ramp output values at progress 0/0.25/0.5/0.75/1.0",
          arguments: [
            (Float(0.0),  Float(0.0)),
            (Float(0.25), Float(0.5) * (1 - cos(Float.pi * 0.25))),  // ≈ 0.14644660...
            (Float(0.5),  Float(0.5)),
            (Float(0.75), Float(0.5) * (1 - cos(Float.pi * 0.75))),  // ≈ 0.85355339...
            (Float(1.0),  Float(1.0)),
          ])
    func halfCosineRampValues(target: Float, expected: Float) {
        // Pre-set progress to `target`, then call with frameCount=0 so delta=0
        // and progress stays exactly at `target`.
        //
        // Quirk: at target == 1.0, the helper's `if progress >= 1.0` branch fires
        // before cos is evaluated — it returns 1.0 directly and flips to phase=2.
        // The mathematical cos(π) = -1 → 0.5*(1-(-1)) = 1.0 happens to agree, but
        // cos itself is never evaluated at exactly 1.0. This test reflects what
        // the helper returns, not what cos would yield.
        var phase: UInt8 = 1
        var progress: Float = target
        var silent: Int32 = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: aboveThreshold,
            frameCount: 0,                       // delta = 0; progress is unchanged by the call
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )

        #expect(abs(mult - expected) < cosineTolerance,
                "at progress=\(target) expected mult≈\(expected), got \(mult)")

        if target >= 1.0 {
            #expect(phase == 2, "progress >= 1.0 must promote to open")
        } else {
            #expect(phase == 1, "progress < 1.0 must stay ramping")
        }
    }
}

// MARK: - Open phase

@Suite("OutputGate — open phase (2)")
struct OutputGateOpenTests {

    @Test("Open + non-silent input resets silentSamples, stays open, returns 1.0")
    func openAndNonSilentResetsSilentCounter() {
        var phase: UInt8 = 2
        var progress: Float = 1.0
        var silent: Int32 = 5000

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: aboveThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )

        #expect(mult == 1.0)
        #expect(phase == 2)
        #expect(silent == 0, "non-silent input must reset silentSamples to 0")
    }

    @Test("Open + silent input accumulates silentSamples by frameCount, stays open, returns 1.0")
    func openAndSilentAccumulatesSilentCounter() {
        var phase: UInt8 = 2
        var progress: Float = 1.0
        var silent: Int32 = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: belowThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )

        #expect(mult == 1.0)
        #expect(phase == 2)
        #expect(silent == 512)
    }

    @Test("Open → armed once silentSamples crosses silenceHoldSamples")
    func openReArmsAfterSilenceHold() {
        var phase: UInt8 = 2
        var progress: Float = 1.0
        var silent: Int32 = 9000  // 600 samples below 9600 hold

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: belowThreshold,
            frameCount: 1024,                       // 9000 + 1024 = 10024 ≥ 9600
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )

        #expect(mult == 1.0, "this buffer is still open passthrough")
        #expect(phase == 0, "must re-arm after hold threshold")
        #expect(silent == 0, "silentSamples reset on re-arm")
        // progress is intentionally NOT reset here — only armed→ramping clears it.
    }
}

// MARK: - Full cycle integration

@Suite("OutputGate — full re-arm cycle")
struct OutputGateCycleTests {

    @Test("open → armed → ramping → open across multiple silent/non-silent transitions")
    func fullReArmCycle() {
        // Start open.
        var phase: UInt8 = 2
        var progress: Float = 1.0
        var silent: Int32 = 0
        let frameCount = 1024

        // Phase 1: feed silent buffers until re-arm.
        // 200 ms hold @ 48 kHz = 9600 samples → 10 × 1024 = 10240 ≥ 9600 → re-arms
        // on the 10th silent buffer (cumulative 9 × 1024 = 9216 still < 9600,
        // 10th call: 9216 + 1024 = 10240 ≥ 9600 → flip).
        var silentBuffersConsumed = 0
        for _ in 0..<20 {
            let mult = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                silentSamples: &silent,
                maxPeak: belowThreshold,
                frameCount: frameCount,
                rampSamples: defaultRampSamples,
                silenceHoldSamples: defaultSilenceHold
            )
            silentBuffersConsumed += 1
            #expect(mult == 1.0, "open passthrough during silence accumulation")
            if phase == 0 { break }
        }
        #expect(phase == 0, "must have re-armed after sustained silence")
        #expect(silentBuffersConsumed <= 10, "should re-arm by buffer 10, got \(silentBuffersConsumed)")

        // Phase 2: feed one armed-silent buffer → stays armed.
        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: belowThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )
        #expect(phase == 0)

        // Phase 3: feed one non-silent buffer → enters ramping (entry returns 0).
        let entryMult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            silentSamples: &silent,
            maxPeak: aboveThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples,
            silenceHoldSamples: defaultSilenceHold
        )
        #expect(entryMult == 0, "armed→ramping entry returns 0")
        #expect(phase == 1)
        #expect(progress == 0)

        // Phase 4: feed enough ramping buffers to reach open.
        // delta per call = 1024/1920 ≈ 0.533 → 2 calls reach progress 1.066 → promote on 2nd.
        var promoted = false
        for _ in 0..<5 {
            let mult = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                silentSamples: &silent,
                maxPeak: aboveThreshold,
                frameCount: frameCount,
                rampSamples: defaultRampSamples,
                silenceHoldSamples: defaultSilenceHold
            )
            if phase == 2 {
                #expect(mult == 1.0, "open output is exactly 1.0")
                promoted = true
                break
            } else {
                #expect(mult >= 0 && mult < 1.0, "ramping output in [0,1)")
            }
        }
        #expect(promoted, "must have reached open phase")
    }
}
