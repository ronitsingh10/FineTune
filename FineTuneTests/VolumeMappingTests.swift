// FineTuneTests/VolumeMappingTests.swift
// Tests for VolumeMapping square-law curve and BoostLevel contracts.
// Pure math — no audio hardware, no CoreAudio.

import Testing
@testable import FineTune

// MARK: - VolumeMapping — Slider to Gain

@Suite("VolumeMapping — sliderToGain square-law curve")
struct VolumeMappingSliderToGainTests {

    @Test("sliderToGain at 0.0 returns 0.0 (silence)")
    func sliderZeroReturnsSilence() {
        #expect(VolumeMapping.sliderToGain(0.0) == 0)
    }

    @Test("sliderToGain at 1.0 returns 1.0 (unity gain)")
    func sliderOneReturnsUnity() {
        #expect(VolumeMapping.sliderToGain(1.0) == 1.0)
    }

    @Test("sliderToGain at 0.5 returns 0.25 (square law: 0.5² = 0.25)")
    func sliderHalfReturnsQuarter() {
        let gain = VolumeMapping.sliderToGain(0.5)
        #expect(abs(gain - 0.25) < 1e-6)
    }

    @Test("sliderToGain is monotonically increasing",
          arguments: [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0])
    func sliderMonotonic(position: Double) {
        let lower = VolumeMapping.sliderToGain(position)
        let upper = VolumeMapping.sliderToGain(min(position + 0.1, 1.0))
        #expect(upper >= lower, "sliderToGain(\(position + 0.1)) should be >= sliderToGain(\(position))")
    }

    @Test("sliderToGain clamps negative input to 0")
    func sliderNegativeClamped() {
        #expect(VolumeMapping.sliderToGain(-0.5) == 0)
        #expect(VolumeMapping.sliderToGain(-100) == 0)
    }

    @Test("sliderToGain clamps input above 1.0")
    func sliderAboveOneClamped() {
        let gain = VolumeMapping.sliderToGain(2.0)
        #expect(gain == 1.0)
    }

    @Test("Square-law known values",
          arguments: [
            (0.0, Float(0.0)),
            (0.1, Float(0.01)),
            (0.25, Float(0.0625)),
            (0.5, Float(0.25)),
            (0.75, Float(0.5625)),
            (1.0, Float(1.0)),
          ])
    func squareLawKnownValues(slider: Double, expectedGain: Float) {
        let gain = VolumeMapping.sliderToGain(slider)
        #expect(abs(gain - expectedGain) < 1e-5,
                "sliderToGain(\(slider)) = \(gain), expected \(expectedGain)")
    }
}

// MARK: - VolumeMapping — Gain to Slider

@Suite("VolumeMapping — gainToSlider inverse square-law")
struct VolumeMappingGainToSliderTests {

    @Test("gainToSlider at 0.0 returns 0.0")
    func gainZeroReturnsZero() {
        #expect(VolumeMapping.gainToSlider(0.0) == 0.0)
    }

    @Test("gainToSlider at 1.0 returns 1.0")
    func gainOneReturnsOne() {
        #expect(VolumeMapping.gainToSlider(1.0) == 1.0)
    }

    @Test("gainToSlider at 0.25 returns 0.5 (sqrt(0.25) = 0.5)")
    func gainQuarterReturnsHalf() {
        let slider = VolumeMapping.gainToSlider(0.25)
        #expect(abs(slider - 0.5) < 1e-6)
    }

    @Test("gainToSlider clamps negative input to 0")
    func gainNegativeClamped() {
        #expect(VolumeMapping.gainToSlider(-0.5) == 0)
    }

    @Test("gainToSlider clamps input above 1.0")
    func gainAboveOneClamped() {
        let slider = VolumeMapping.gainToSlider(2.0)
        #expect(abs(slider - 1.0) < 1e-6)
    }

    @Test("Round-trip: sliderToGain → gainToSlider recovers original",
          arguments: [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0])
    func roundTrip(original: Double) {
        let gain = VolumeMapping.sliderToGain(original)
        let recovered = VolumeMapping.gainToSlider(gain)
        #expect(abs(recovered - original) < 1e-5,
                "Round-trip failed: \(original) → \(gain) → \(recovered)")
    }
}

// MARK: - BoostLevel

@Suite("BoostLevel — Enumeration and cycling")
struct BoostLevelTests {

    @Test("allCases has exactly 4 levels")
    func allCasesCount() {
        #expect(BoostLevel.allCases.count == 4)
    }

    @Test("Raw values match expected multipliers",
          arguments: [
            (BoostLevel.x1, Float(1.0)),
            (BoostLevel.x2, Float(2.0)),
            (BoostLevel.x3, Float(3.0)),
            (BoostLevel.x4, Float(4.0)),
          ])
    func rawValues(level: BoostLevel, expected: Float) {
        #expect(level.rawValue == expected)
    }

    @Test("next cycles through all levels and wraps")
    func nextCycles() {
        #expect(BoostLevel.x1.next == .x2)
        #expect(BoostLevel.x2.next == .x3)
        #expect(BoostLevel.x3.next == .x4)
        #expect(BoostLevel.x4.next == .x1)
    }

    @Test("isBoosted is false only for x1")
    func isBoosted() {
        #expect(!BoostLevel.x1.isBoosted)
        #expect(BoostLevel.x2.isBoosted)
        #expect(BoostLevel.x3.isBoosted)
        #expect(BoostLevel.x4.isBoosted)
    }

    @Test("Labels match expected format",
          arguments: [
            (BoostLevel.x1, "1x"),
            (BoostLevel.x2, "2x"),
            (BoostLevel.x3, "3x"),
            (BoostLevel.x4, "4x"),
          ])
    func labels(level: BoostLevel, expected: String) {
        #expect(level.label == expected)
    }

    @Test("BoostLevel can be initialized from raw value")
    func initFromRawValue() {
        #expect(BoostLevel(rawValue: 1.0) == .x1)
        #expect(BoostLevel(rawValue: 2.0) == .x2)
        #expect(BoostLevel(rawValue: 3.0) == .x3)
        #expect(BoostLevel(rawValue: 4.0) == .x4)
        #expect(BoostLevel(rawValue: 1.5) == nil)
        #expect(BoostLevel(rawValue: 0.0) == nil)
    }
}
