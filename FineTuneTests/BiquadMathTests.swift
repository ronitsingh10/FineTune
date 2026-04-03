// FineTuneTests/BiquadMathTests.swift
// Tests for BiquadMath coefficient calculations.
// Verifies against known analytical results from the Audio EQ Cookbook.
// Pure math — no audio hardware, no vDSP.

import Testing
@testable import FineTune

// MARK: - Peaking EQ Coefficients

@Suite("BiquadMath — Peaking EQ coefficients")
struct BiquadMathPeakingTests {

    @Test("0 dB gain returns unity passthrough coefficients")
    func zeroGainIsUnity() {
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 0, q: 1.0, sampleRate: 48000
        )
        #expect(coeffs.count == 5)
        // At 0 dB: A=1, so b0=a0, b1=a1, b2=a2 → normalized: b0/a0=1, b1/a0=a1/a0, b2/a0=a2/a0
        #expect(abs(coeffs[0] - 1.0) < 1e-10, "b0/a0 should be 1.0 at 0dB gain")
        #expect(abs(coeffs[1] - coeffs[3]) < 1e-10, "b1/a0 should equal a1/a0 at 0dB gain")
        #expect(abs(coeffs[2] - coeffs[4]) < 1e-10, "b2/a0 should equal a2/a0 at 0dB gain")
    }

    @Test("Positive gain: b0/a0 > 1 (boost)")
    func positiveGainBoosts() {
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 6, q: 1.4, sampleRate: 48000
        )
        #expect(coeffs[0] > 1.0, "b0/a0 should be > 1 for positive gain")
    }

    @Test("Negative gain: b0/a0 < 1 (cut)")
    func negativeGainCuts() {
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: -6, q: 1.4, sampleRate: 48000
        )
        #expect(coeffs[0] < 1.0, "b0/a0 should be < 1 for negative gain")
    }

    @Test("Boost and cut are reciprocal: swapping numerator/denominator",
          arguments: [Float(3.0), Float(6.0), Float(12.0)])
    func boostCutSymmetry(gainDB: Float) {
        let boost = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: gainDB, q: 1.4, sampleRate: 48000
        )
        let cut = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: -gainDB, q: 1.4, sampleRate: 48000
        )
        // Peaking EQ symmetry: boost filter's numerator = cut filter's denominator
        // In normalized form: boost's [b0,b1,b2]/a0 should relate to cut's [1,a1,a2]/a0
        // Specifically: boost[0] * cut[0] + boost[1]*cut[1] relationship holds
        // Simpler property: boost b0 > 1 and cut b0 < 1 (already tested), and
        // the product b0_boost * b0_cut ≈ 1 (within tolerance due to normalization)
        let product = boost[0] * cut[0]
        // This relationship holds because for peaking EQ:
        // b0_boost = (1 + alpha*A), a0_boost = (1 + alpha/A)
        // b0_cut = (1 + alpha/A), a0_cut = (1 + alpha*A)
        // So (b0_boost/a0_boost) * (b0_cut/a0_cut) = 1.0
        #expect(abs(product - 1.0) < 1e-10,
                "b0_boost * b0_cut should equal 1.0 (reciprocal filters), got \(product)")
    }

    @Test("Always returns exactly 5 coefficients")
    func coefficientCount() {
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 440, gainDB: 3.0, q: 0.707, sampleRate: 44100
        )
        #expect(coeffs.count == 5)
    }

    @Test("All coefficients are finite for valid inputs")
    func allFinite() {
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 12, q: 1.4, sampleRate: 48000
        )
        for (i, c) in coeffs.enumerated() {
            #expect(c.isFinite, "Coefficient[\(i)] is not finite: \(c)")
        }
    }

    @Test("Peaking EQ at different sample rates produces different coefficients")
    func sampleRateAffectsCoefficients() {
        let coeffs44 = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 6, q: 1.4, sampleRate: 44100
        )
        let coeffs48 = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 6, q: 1.4, sampleRate: 48000
        )
        let coeffs96 = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 6, q: 1.4, sampleRate: 96000
        )
        // b1 = -2*cos(omega)/a0 where omega = 2π*f/fs, so different fs → different b1
        #expect(coeffs44[1] != coeffs48[1])
        #expect(coeffs48[1] != coeffs96[1])
    }
}

// MARK: - Shelf Coefficients

@Suite("BiquadMath — Shelf filter coefficients")
struct BiquadMathShelfTests {

    @Test("Low shelf at 0 dB returns near-unity passthrough")
    func lowShelfZeroGain() {
        let coeffs = BiquadMath.lowShelfCoefficients(
            frequency: 100, gainDB: 0, q: 0.707, sampleRate: 48000
        )
        #expect(coeffs.count == 5)
        #expect(abs(coeffs[0] - 1.0) < 0.01, "b0/a0 should be ~1.0 at 0dB, got \(coeffs[0])")
    }

    @Test("High shelf at 0 dB returns near-unity passthrough")
    func highShelfZeroGain() {
        let coeffs = BiquadMath.highShelfCoefficients(
            frequency: 8000, gainDB: 0, q: 0.707, sampleRate: 48000
        )
        #expect(coeffs.count == 5)
        #expect(abs(coeffs[0] - 1.0) < 0.01, "b0/a0 should be ~1.0 at 0dB, got \(coeffs[0])")
    }

    @Test("Low shelf with positive gain boosts DC (b0 > 1)")
    func lowShelfPositiveGain() {
        let coeffs = BiquadMath.lowShelfCoefficients(
            frequency: 100, gainDB: 6, q: 0.707, sampleRate: 48000
        )
        // At DC (ω=0): H(z) = A, so for boost A > 1. b0/a0 contributes to this.
        #expect(coeffs[0] > 1.0)
    }

    @Test("High shelf with positive gain boosts (b0 > a0-normalized)")
    func highShelfPositiveGain() {
        let coeffs = BiquadMath.highShelfCoefficients(
            frequency: 8000, gainDB: 6, q: 0.707, sampleRate: 48000
        )
        #expect(coeffs[0] > 1.0)
    }

    @Test("All shelf coefficients are finite",
          arguments: [
            ("lowShelf", 100.0, Float(12.0)),
            ("lowShelf", 100.0, Float(-12.0)),
            ("highShelf", 8000.0, Float(12.0)),
            ("highShelf", 8000.0, Float(-12.0)),
          ])
    func shelfCoefficientsFinite(type: String, freq: Double, gain: Float) {
        let coeffs: [Double]
        if type == "lowShelf" {
            coeffs = BiquadMath.lowShelfCoefficients(frequency: freq, gainDB: gain, q: 0.707, sampleRate: 48000)
        } else {
            coeffs = BiquadMath.highShelfCoefficients(frequency: freq, gainDB: gain, q: 0.707, sampleRate: 48000)
        }
        for (i, c) in coeffs.enumerated() {
            #expect(c.isFinite, "\(type) coefficient[\(i)] is not finite: \(c)")
        }
    }
}

// MARK: - coefficientsForAllBands

@Suite("BiquadMath — coefficientsForAllBands")
struct BiquadMathAllBandsTests {

    @Test("Returns 50 coefficients for 10 bands (5 per band)")
    func returns50Coefficients() {
        let gains: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        #expect(coeffs.count == 50)
    }

    @Test("Wrong band count returns unity passthrough for all bands")
    func wrongBandCountReturnsUnity() {
        let coeffs = BiquadMath.coefficientsForAllBands(gains: [1.0, 2.0], sampleRate: 48000)
        #expect(coeffs.count == 50)
        // Each band should be [1, 0, 0, 0, 0] (passthrough)
        for band in 0..<EQSettings.bandCount {
            let offset = band * 5
            #expect(coeffs[offset] == 1.0, "Band \(band) b0 should be 1.0")
            #expect(coeffs[offset + 1] == 0.0, "Band \(band) b1 should be 0.0")
            #expect(coeffs[offset + 2] == 0.0, "Band \(band) b2 should be 0.0")
            #expect(coeffs[offset + 3] == 0.0, "Band \(band) a1 should be 0.0")
            #expect(coeffs[offset + 4] == 0.0, "Band \(band) a2 should be 0.0")
        }
    }

    @Test("Band at or above Nyquist is bypassed with unity")
    func nyquistBypass() {
        // At 22050 Hz sample rate, the 16kHz band (index 9) is below Nyquist (11025)
        // but let's use a very low sample rate where 16kHz exceeds Nyquist
        let gains: [Float] = [6, 6, 6, 6, 6, 6, 6, 6, 6, 6]
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 22050)
        // 16000 Hz >= 22050/2 = 11025 Hz → band 9 should be unity
        // 8000 Hz < 11025 Hz → band 8 should NOT be unity
        let band9Offset = 9 * 5
        #expect(coeffs[band9Offset] == 1.0, "16kHz band should be unity at 22050 Hz sample rate")
        #expect(coeffs[band9Offset + 1] == 0.0)
    }

    @Test("All coefficients finite at standard sample rates",
          arguments: [44100.0, 48000.0, 96000.0])
    func allCoefficientsFinite(sampleRate: Double) {
        let gains: [Float] = [6, -3, 0, 12, -12, 6, -6, 3, -3, 0]
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: sampleRate)
        for (i, c) in coeffs.enumerated() {
            #expect(c.isFinite, "Coefficient[\(i)] at \(sampleRate) Hz is not finite: \(c)")
        }
    }
}

// MARK: - preWarpFrequency

@Suite("BiquadMath — Frequency pre-warping")
struct BiquadMathPreWarpTests {

    @Test("Same source and target rate returns approximately the same frequency")
    func sameRateIdentity() {
        let freq = BiquadMath.preWarpFrequency(1000, from: 48000, to: 48000)
        #expect(abs(freq - 1000) < 0.1, "Same rate should return ~same frequency, got \(freq)")
    }

    @Test("Pre-warping low frequency shows minimal shift")
    func lowFrequencyMinimalShift() {
        // At low frequencies, bilinear transform warping is minimal
        let freq = BiquadMath.preWarpFrequency(100, from: 48000, to: 96000)
        // Should be close to 100 (low freq → minimal warping)
        #expect(abs(freq - 100) < 5, "Low frequency pre-warp shift should be small, got \(freq)")
    }

    @Test("Pre-warping higher frequency shows larger shift")
    func highFrequencyLargerShift() {
        let low = BiquadMath.preWarpFrequency(100, from: 48000, to: 96000)
        let high = BiquadMath.preWarpFrequency(10000, from: 48000, to: 96000)
        let lowDelta = abs(low - 100)
        let highDelta = abs(high - 10000)
        #expect(highDelta > lowDelta,
                "Higher frequencies should warp more than lower ones")
    }

    @Test("Pre-warped frequency is positive for valid inputs")
    func positiveResult() {
        let freq = BiquadMath.preWarpFrequency(5000, from: 44100, to: 96000)
        #expect(freq > 0, "Pre-warped frequency should be positive")
    }

    @Test("Pre-warped frequency is finite")
    func finiteResult() {
        let freq = BiquadMath.preWarpFrequency(1000, from: 48000, to: 44100)
        #expect(freq.isFinite)
    }
}
