// FineTuneTests/CrossfadeStateAdversarialTests.swift
// Adversarial tests for CrossfadeState.
// Targets: equal-power invariant, phase transition correctness,
// progress monotonicity and bounds, multiplier continuity,
// warmup/completion thresholds, and out-of-order operations.

import Testing
@testable import FineTune

// MARK: - Equal-Power Crossfade Invariant

@Suite("CrossfadeState — Equal-Power Invariant (Adversarial)")
struct CrossfadeEqualPowerTests {

    @Test("primary^2 + secondary^2 = 1.0 during crossfading phase",
          arguments: [Float(0.0), 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45,
                      0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0])
    func equalPowerDuringCrossfade(progress: Float) {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = progress

        let p = state.primaryMultiplier
        let s = state.secondaryMultiplier
        let powerSum = p * p + s * s
        #expect(abs(powerSum - 1.0) < 1e-5,
                "Equal-power violated at progress=\(progress): p=\(p) s=\(s) p^2+s^2=\(powerSum)")
    }

    @Test("Multiplier boundary: progress=0 -> full primary, zero secondary")
    func progressZeroBoundary() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = 0

        #expect(state.primaryMultiplier == 1.0, "At progress=0, primary should be 1.0")
        #expect(state.secondaryMultiplier == 0.0, "At progress=0, secondary should be 0.0")
    }

    @Test("Multiplier boundary: progress=1 -> zero primary, full secondary")
    func progressOneBoundary() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = 1.0

        let primary = state.primaryMultiplier
        let secondary = state.secondaryMultiplier
        #expect(abs(primary) < 1e-7, "At progress=1, primary should be ~0, got \(primary)")
        #expect(abs(secondary - 1.0) < 1e-7, "At progress=1, secondary should be ~1, got \(secondary)")
    }

    @Test("Primary multiplier monotonically decreases during crossfade")
    func primaryMonotonicallyDecreases() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()

        var prevPrimary: Float = 2.0  // > any valid multiplier
        for i in 0...100 {
            state.progress = Float(i) / 100.0
            let p = state.primaryMultiplier
            #expect(p <= prevPrimary,
                    "Primary should decrease: at \(state.progress), p=\(p) > prev=\(prevPrimary)")
            prevPrimary = p
        }
    }

    @Test("Secondary multiplier monotonically increases during crossfade")
    func secondaryMonotonicallyIncreases() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()

        var prevSecondary: Float = -1.0  // < any valid multiplier
        for i in 0...100 {
            state.progress = Float(i) / 100.0
            let s = state.secondaryMultiplier
            #expect(s >= prevSecondary,
                    "Secondary should increase: at \(state.progress), s=\(s) < prev=\(prevSecondary)")
            prevSecondary = s
        }
    }
}

// MARK: - Phase Transitions

@Suite("CrossfadeState — Phase Transitions (Adversarial)")
struct CrossfadePhaseTransitionTests {

    @Test("Full lifecycle: idle -> warmingUp -> crossfading -> idle")
    func fullLifecycle() {
        var state = CrossfadeState()
        #expect(state.phase == .idle)
        #expect(!state.isActive)

        state.beginWarmup()
        #expect(state.phase == .warmingUp)
        #expect(state.isActive)
        #expect(state.progress == 0)
        #expect(state.secondarySampleCount == 0)

        state.totalSamples = 24000

        state.beginCrossfading()
        #expect(state.phase == .crossfading)
        #expect(state.isActive)
        #expect(state.progress == 0)
        #expect(state.secondarySampleCount == 0)
        // totalSamples should be preserved across beginCrossfading
        #expect(state.totalSamples == 24000)

        state.complete()
        #expect(state.phase == .idle)
        #expect(!state.isActive)
        #expect(state.progress == 0)
        #expect(state.totalSamples == 0)
    }

    @Test("Warmup phase: primary=1, secondary=0 regardless of samples processed")
    func warmupFixedMultipliers() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000

        // Process several buffers during warmup
        for _ in 0..<10 {
            _ = state.updateProgress(samples: 512)
        }

        #expect(state.primaryMultiplier == 1.0, "During warmup, primary must be 1.0")
        #expect(state.secondaryMultiplier == 0.0, "During warmup, secondary must be 0.0")
        #expect(state.progress == 0, "Progress should not advance during warmup")
    }

    @Test("Idle phase after init: primary=1, secondary=1")
    func idleAfterInit() {
        let state = CrossfadeState()
        #expect(state.primaryMultiplier == 1.0)
        #expect(state.secondaryMultiplier == 1.0)
    }

    @Test("Idle phase after complete: primary=1, secondary=1 (progress reset to 0)")
    func idleAfterComplete() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = 0.5
        state.complete()

        #expect(state.progress == 0)
        #expect(state.primaryMultiplier == 1.0)
        #expect(state.secondaryMultiplier == 1.0)
    }

    @Test("Double complete() is safe (idempotent reset)")
    func doubleComplete() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = 0.7

        state.complete()
        state.complete()

        #expect(state.phase == .idle)
        #expect(state.progress == 0)
        #expect(!state.isActive)
    }

    @Test("beginWarmup during crossfading: full reset, multipliers snap to warmup values")
    func warmupDuringCrossfade() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = 0.5  // Mid-crossfade

        // Interrupt with new warmup (device switch during crossfade)
        state.beginWarmup()

        #expect(state.phase == .warmingUp)
        #expect(state.progress == 0)
        #expect(state.secondarySampleCount == 0)
        #expect(state.secondarySamplesProcessed == 0)
        #expect(state.primaryMultiplier == 1.0, "After re-warmup, primary should be 1.0")
        #expect(state.secondaryMultiplier == 0.0, "After re-warmup, secondary should be 0.0")
    }
}

// MARK: - Progress Mechanics

@Suite("CrossfadeState — Progress Mechanics (Adversarial)")
struct CrossfadeProgressTests {

    @Test("updateProgress: progress monotonically increases during crossfading")
    func progressMonotonicity() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()

        var prevProgress: Float = -1
        for _ in 0..<100 {
            let p = state.updateProgress(samples: 512)
            #expect(p >= prevProgress,
                    "Progress should monotonically increase: \(p) < prev \(prevProgress)")
            prevProgress = p
        }
    }

    @Test("updateProgress: progress clamped at 1.0 (never exceeds)")
    func progressClampedAtOne() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 1000  // Short crossfade
        state.beginCrossfading()

        // Process way more samples than totalSamples
        for _ in 0..<100 {
            let p = state.updateProgress(samples: 512)
            #expect(p <= 1.0, "Progress must never exceed 1.0, got \(p)")
        }
    }

    @Test("updateProgress: totalSamples=0 defense (progress clamps to 1.0 immediately)")
    func totalSamplesZeroDefense() {
        var state = CrossfadeState()
        state.beginWarmup()
        // totalSamples stays 0 (never set — usage error, but defended against)
        state.beginCrossfading()

        let p = state.updateProgress(samples: 1)
        // max(1, 0) = 1, so progress = min(1.0, 1/1) = 1.0
        #expect(p == 1.0, "With totalSamples=0, any progress should clamp to 1.0, got \(p)")
        #expect(state.isCrossfadeComplete)
    }

    @Test("updateProgress in warmup phase: increments secondarySamplesProcessed, not progress")
    func updateProgressDuringWarmup() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000

        let p = state.updateProgress(samples: 512)
        #expect(p == 0, "Progress should not advance during warmup")
        #expect(state.secondarySamplesProcessed == 512)

        _ = state.updateProgress(samples: 512)
        #expect(state.progress == 0)
        #expect(state.secondarySamplesProcessed == 1024)
    }

    @Test("updateProgress in idle phase: increments secondarySamplesProcessed only")
    func updateProgressDuringIdle() {
        var state = CrossfadeState()
        let p = state.updateProgress(samples: 512)
        #expect(p == 0, "Progress should be 0 in idle")
        #expect(state.secondarySamplesProcessed == 512)
    }

    @Test("isWarmupComplete: transitions at exactly minimumWarmupSamples")
    func warmupCompletionThreshold() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000

        // Process just under the threshold
        _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples - 1)
        #expect(!state.isWarmupComplete,
                "Should NOT be complete at \(CrossfadeState.minimumWarmupSamples - 1) samples")

        // Process one more sample to hit exactly the threshold
        _ = state.updateProgress(samples: 1)
        #expect(state.isWarmupComplete,
                "Should be complete at exactly \(CrossfadeState.minimumWarmupSamples) samples")
    }

    @Test("isCrossfadeComplete: true when progress >= 1.0")
    func crossfadeCompleteThreshold() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()

        state.progress = 0.999
        #expect(!state.isCrossfadeComplete, "Should not be complete at 0.999")

        state.progress = 1.0
        #expect(state.isCrossfadeComplete, "Should be complete at exactly 1.0")
    }

    @Test("Normal crossfade timing: progress reaches 1.0 at totalSamples")
    func crossfadeTiming() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 4800  // 100ms at 48kHz
        state.beginCrossfading()

        // Process in 480-sample buffers (10ms each) — should take ~10 buffers
        var buffers = 0
        while !state.isCrossfadeComplete {
            _ = state.updateProgress(samples: 480)
            buffers += 1
            if buffers > 100 { break }  // Safety valve
        }

        #expect(buffers == 10, "Crossfade should complete in exactly 10 buffers, took \(buffers)")
        #expect(state.progress == 1.0)
    }

    @Test("Large buffer sizes: single buffer can complete entire crossfade")
    func singleBufferComplete() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 1000
        state.beginCrossfading()

        let p = state.updateProgress(samples: 2000)
        #expect(p == 1.0, "Large buffer should clamp progress to 1.0")
        #expect(state.isCrossfadeComplete)
    }

    @Test("beginCrossfading preserves totalSamples set during warmup")
    func totalSamplesPreserved() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 24000

        state.beginCrossfading()
        // beginCrossfading resets secondarySampleCount and progress, but NOT totalSamples
        #expect(state.totalSamples == 24000,
                "totalSamples should survive beginCrossfading, got \(state.totalSamples)")
    }

    @Test("complete() resets all state including totalSamples")
    func completeResetsAll() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 24000
        state.beginCrossfading()
        _ = state.updateProgress(samples: 12000)

        state.complete()

        #expect(state.progress == 0)
        #expect(state.secondarySampleCount == 0)
        #expect(state.secondarySamplesProcessed == 0)
        #expect(state.totalSamples == 0)
        #expect(state.phase == .idle)
    }
}

// MARK: - Idle Phase Edge Cases

@Suite("CrossfadeState — Idle Phase Multipliers (Adversarial)")
struct CrossfadeIdleTests {

    @Test("Idle with progress >= 1.0: primary=0, secondary=1 (post-crossfade window)")
    func idlePostCrossfadeWindow() {
        // This state occurs between the audio thread detecting progress >= 1.0
        // and the main thread calling complete(). The multipliers should reflect
        // "crossfade done, secondary is promoted."
        var state = CrossfadeState()
        state.progress = 1.0
        // Phase is idle (default), but progress indicates crossfade was completed

        #expect(state.primaryMultiplier == 0.0,
                "Post-crossfade idle with progress=1: primary should be 0")
        #expect(state.secondaryMultiplier == 1.0,
                "Post-crossfade idle with progress=1: secondary should be 1")
    }

    @Test("Idle with progress < 1.0: primary=1, secondary=1 (normal idle)")
    func idleNormalState() {
        var state = CrossfadeState()
        state.progress = 0.0
        #expect(state.primaryMultiplier == 1.0)
        #expect(state.secondaryMultiplier == 1.0)

        state.progress = 0.5
        #expect(state.primaryMultiplier == 1.0,
                "Idle with progress < 1.0 should have primary=1")
        #expect(state.secondaryMultiplier == 1.0)
    }

    @Test("minimumWarmupSamples is a reasonable value")
    func warmupSamplesReasonable() {
        let samples = CrossfadeState.minimumWarmupSamples
        #expect(samples == 2048, "minimumWarmupSamples should be 2048")
        // At 48kHz: 2048/48000 ≈ 42.7ms — enough for secondary tap to stabilize
        let durationMs = Double(samples) / 48000.0 * 1000.0
        #expect(durationMs > 20, "Warmup should be > 20ms, is \(durationMs)ms")
        #expect(durationMs < 100, "Warmup should be < 100ms, is \(durationMs)ms")
    }
}
