// FineTuneTests/BiquadMathAdversarialTests.swift
// Adversarial tests for BiquadMath coefficient calculations.
// Targets: pole stability across extreme parameters, frequency response
// verification against known analytical properties, boundary conditions.
// Pure math — no audio hardware, no vDSP runtime.

import Foundation
import Testing
@testable import FineTune

// MARK: - Pole Stability

@Suite("BiquadMath — Pole Stability (Adversarial)")
struct BiquadMathPoleStabilityTests {

    /// Jury stability criteria for the denominator z^2 + a1*z + a2:
    /// Stable iff |a2| < 1, 1+a1+a2 > 0, and 1-a1+a2 > 0.
    /// Uses a small negative tolerance (-1e-10) to accommodate floating-point rounding.
    private static func assertStable(
        _ coeffs: [Double],
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let a1 = coeffs[3]
        let a2 = coeffs[4]
        #expect(abs(a2) < 1.0,
                "\(label): |a2|=\(abs(a2)) must be < 1 (pole on/outside unit circle)",
                sourceLocation: sourceLocation)
        #expect(1.0 + a1 + a2 > -1e-10,
                "\(label): Jury f(1)=\(1.0 + a1 + a2) must be > 0 (z=+1 boundary)",
                sourceLocation: sourceLocation)
        #expect(1.0 - a1 + a2 > -1e-10,
                "\(label): Jury f(-1)=\(1.0 - a1 + a2) must be > 0 (z=-1 boundary)",
                sourceLocation: sourceLocation)
    }

    @Test("Exhaustive stability: peaking EQ across full parameter grid")
    func peakingExhaustiveGrid() {
        let frequencies = [20.0, 100.0, 500.0, 1000.0, 5000.0, 10000.0, 20000.0]
        let gains: [Float] = [-24, -12, -6, 0, 6, 12, 24]
        let qValues = [0.1, 0.5, 0.707, 1.4, 5.0, 10.0, 30.0]
        let sampleRates = [8000.0, 22050.0, 44100.0, 48000.0, 96000.0, 192000.0]

        var count = 0
        for sr in sampleRates {
            for freq in frequencies {
                guard freq < sr / 2.0 else { continue }
                for gain in gains {
                    for q in qValues {
                        let coeffs = BiquadMath.peakingEQCoefficients(
                            frequency: freq, gainDB: gain, q: q, sampleRate: sr
                        )
                        for (i, c) in coeffs.enumerated() {
                            #expect(c.isFinite,
                                    "coeff[\(i)] non-finite at f=\(freq) g=\(gain) Q=\(q) sr=\(sr)")
                        }
                        Self.assertStable(coeffs,
                            label: "peaking f=\(freq) g=\(gain) Q=\(q) sr=\(sr)")
                        count += 1
                    }
                }
            }
        }
        #expect(count > 500, "Tested \(count) combinations — expected > 500")
    }

    @Test("Exhaustive stability: low shelf across parameter grid")
    func lowShelfExhaustiveGrid() {
        let frequencies = [20.0, 50.0, 100.0, 200.0, 500.0]
        let gains: [Float] = [-24, -12, -6, 0, 6, 12, 24]
        let qValues = [0.1, 0.5, 0.707, 1.4, 5.0]
        let sampleRates = [8000.0, 44100.0, 48000.0, 96000.0]

        var count = 0
        for sr in sampleRates {
            for freq in frequencies {
                guard freq < sr / 2.0 else { continue }
                for gain in gains {
                    for q in qValues {
                        let coeffs = BiquadMath.lowShelfCoefficients(
                            frequency: freq, gainDB: gain, q: q, sampleRate: sr
                        )
                        for (i, c) in coeffs.enumerated() {
                            #expect(c.isFinite,
                                    "lowShelf coeff[\(i)] non-finite at f=\(freq) g=\(gain) Q=\(q) sr=\(sr)")
                        }
                        Self.assertStable(coeffs,
                            label: "lowShelf f=\(freq) g=\(gain) Q=\(q) sr=\(sr)")
                        count += 1
                    }
                }
            }
        }
        #expect(count > 200, "Tested \(count) low shelf combinations")
    }

    @Test("Exhaustive stability: high shelf across parameter grid")
    func highShelfExhaustiveGrid() {
        let frequencies = [1000.0, 2000.0, 4000.0, 8000.0, 16000.0]
        let gains: [Float] = [-24, -12, -6, 0, 6, 12, 24]
        let qValues = [0.1, 0.5, 0.707, 1.4, 5.0]
        let sampleRates = [44100.0, 48000.0, 96000.0, 192000.0]

        var count = 0
        for sr in sampleRates {
            for freq in frequencies {
                guard freq < sr / 2.0 else { continue }
                for gain in gains {
                    for q in qValues {
                        let coeffs = BiquadMath.highShelfCoefficients(
                            frequency: freq, gainDB: gain, q: q, sampleRate: sr
                        )
                        for (i, c) in coeffs.enumerated() {
                            #expect(c.isFinite,
                                    "highShelf coeff[\(i)] non-finite at f=\(freq) g=\(gain) Q=\(q) sr=\(sr)")
                        }
                        Self.assertStable(coeffs,
                            label: "highShelf f=\(freq) g=\(gain) Q=\(q) sr=\(sr)")
                        count += 1
                    }
                }
            }
        }
        #expect(count > 200, "Tested \(count) high shelf combinations")
    }

    @Test("Worst-case combo: near-Nyquist + low Q + max gain at Bluetooth HFP rate")
    func worstCaseCombination() {
        // Pushes poles closest to z=-1 stability boundary
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 3500, gainDB: 24, q: 0.1, sampleRate: 8000
        )
        Self.assertStable(coeffs, label: "worst-case f=3500 g=24 Q=0.1 sr=8000")
    }

    @Test("Production EQ bands: all stable at max gain across standard sample rates",
          arguments: [44100.0, 48000.0, 96000.0])
    func productionBandsMaxGain(sampleRate: Double) {
        let gains: [Float] = Array(repeating: EQSettings.maxGainDB, count: EQSettings.bandCount)
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: sampleRate)
        let nyquist = sampleRate / 2.0
        for band in 0..<EQSettings.bandCount {
            let freq = EQSettings.frequencies[band]
            guard freq < nyquist else { continue }
            let section = Array(coeffs[(band * 5)..<(band * 5 + 5)])
            Self.assertStable(section, label: "band \(band) (\(freq) Hz) at \(sampleRate) Hz")
        }
    }

    @Test("Frequency at 0 Hz: marginally stable (poles on unit circle)")
    func frequencyZeroMarginallyStable() {
        // omega=0 → alpha=0 → a2=1.0 (ON the unit circle, not inside)
        // Production never hits this — lowest band is 31.25 Hz.
        // Documenting the precondition: frequency must be > 0 for strict stability.
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 0, gainDB: 6, q: 1.4, sampleRate: 48000
        )
        let a2 = coeffs[4]
        #expect(abs(a2 - 1.0) < 1e-10,
                "At frequency=0, a2 should be exactly 1.0 (marginally stable), got \(a2)")
    }
}

// MARK: - Frequency Response Verification

@Suite("BiquadMath — Frequency Response Properties (Adversarial)")
struct BiquadMathFrequencyResponseTests {

    /// Evaluate biquad magnitude response |H(e^jw)| at normalized frequency omega.
    private static func magnitudeResponse(
        coefficients c: [Double],
        atNormalizedFrequency omega: Double
    ) -> Double {
        let cosW = cos(omega), sinW = sin(omega)
        let cos2W = cos(2 * omega), sin2W = sin(2 * omega)

        let numR = c[0] + c[1] * cosW + c[2] * cos2W
        let numI = -(c[1] * sinW + c[2] * sin2W)
        let denR = 1.0 + c[3] * cosW + c[4] * cos2W
        let denI = -(c[3] * sinW + c[4] * sin2W)

        return sqrt((numR * numR + numI * numI) / (denR * denR + denI * denI))
    }

    @Test("Peaking EQ has exact unity gain at DC (omega=0) for any gain setting",
          arguments: [Float(-24), Float(-12), Float(-6), Float(6), Float(12), Float(24)])
    func peakingUnityAtDC(gainDB: Float) {
        // Analytical proof: at z=1, (b0+b1+b2)/(a0+a1+a2) = (2-2cosW)/(2-2cosW) = 1
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: gainDB, q: 1.4, sampleRate: 48000
        )
        let mag = Self.magnitudeResponse(coefficients: coeffs, atNormalizedFrequency: 0)
        #expect(abs(mag - 1.0) < 1e-10,
                "Peaking EQ at DC must be exactly unity, got \(mag) for \(gainDB)dB")
    }

    @Test("Peaking EQ has exact unity gain at Nyquist for any gain setting",
          arguments: [Float(-24), Float(-12), Float(6), Float(12), Float(24)])
    func peakingUnityAtNyquist(gainDB: Float) {
        // Analytical proof: at z=-1, (b0-b1+b2)/(a0-a1+a2) = (2+2cosW)/(2+2cosW) = 1
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: gainDB, q: 1.4, sampleRate: 48000
        )
        let mag = Self.magnitudeResponse(coefficients: coeffs, atNormalizedFrequency: .pi)
        #expect(abs(mag - 1.0) < 1e-10,
                "Peaking EQ at Nyquist must be exactly unity, got \(mag) for \(gainDB)dB")
    }

    @Test("Peaking EQ: gain at center frequency matches specified gain (within 0.5 dB)",
          arguments: [Float(-12), Float(-6), Float(-3), Float(3), Float(6), Float(12)])
    func peakingGainAtCenter(gainDB: Float) {
        let freq = 1000.0, sr = 48000.0
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: freq, gainDB: gainDB, q: 1.4, sampleRate: sr
        )
        let omega = 2.0 * .pi * freq / sr
        let mag = Self.magnitudeResponse(coefficients: coeffs, atNormalizedFrequency: omega)
        let magDB = 20.0 * log10(mag)
        #expect(abs(magDB - Double(gainDB)) < 0.5,
                "Peaking at center: expected \(gainDB)dB, got \(String(format: "%.3f", magDB))dB")
    }

    @Test("Low shelf: DC gain equals specified linear gain",
          arguments: [Float(-12), Float(-6), Float(6), Float(12)])
    func lowShelfDCGain(gainDB: Float) {
        // At DC: H(z=1) = A^2 where A = 10^(gainDB/40), so linear gain = 10^(gainDB/20)
        let coeffs = BiquadMath.lowShelfCoefficients(
            frequency: 100, gainDB: gainDB, q: 0.707, sampleRate: 48000
        )
        let mag = Self.magnitudeResponse(coefficients: coeffs, atNormalizedFrequency: 0)
        let expectedLinear = pow(10.0, Double(gainDB) / 20.0)
        #expect(abs(mag - expectedLinear) / expectedLinear < 0.01,
                "Low shelf DC gain: expected \(expectedLinear), got \(mag)")
    }

    @Test("Low shelf: near-unity gain at Nyquist (high freqs unaffected)",
          arguments: [Float(-12), Float(6), Float(12)])
    func lowShelfNyquistUnity(gainDB: Float) {
        let coeffs = BiquadMath.lowShelfCoefficients(
            frequency: 100, gainDB: gainDB, q: 0.707, sampleRate: 48000
        )
        let mag = Self.magnitudeResponse(coefficients: coeffs, atNormalizedFrequency: .pi - 0.001)
        #expect(abs(mag - 1.0) < 0.05,
                "Low shelf at Nyquist should be ~unity, got \(mag)")
    }

    @Test("High shelf: near-unity gain at DC (low freqs unaffected)",
          arguments: [Float(-12), Float(6), Float(12)])
    func highShelfDCUnity(gainDB: Float) {
        let coeffs = BiquadMath.highShelfCoefficients(
            frequency: 8000, gainDB: gainDB, q: 0.707, sampleRate: 48000
        )
        let mag = Self.magnitudeResponse(coefficients: coeffs, atNormalizedFrequency: 0)
        #expect(abs(mag - 1.0) < 0.05,
                "High shelf at DC should be ~unity, got \(mag)")
    }

    @Test("High shelf: gain at Nyquist equals specified linear gain",
          arguments: [Float(-12), Float(6), Float(12)])
    func highShelfNyquistGain(gainDB: Float) {
        let coeffs = BiquadMath.highShelfCoefficients(
            frequency: 8000, gainDB: gainDB, q: 0.707, sampleRate: 48000
        )
        let mag = Self.magnitudeResponse(coefficients: coeffs, atNormalizedFrequency: .pi - 0.001)
        let expectedLinear = pow(10.0, Double(gainDB) / 20.0)
        #expect(abs(mag - expectedLinear) / expectedLinear < 0.15,
                "High shelf at Nyquist: expected \(expectedLinear), got \(mag)")
    }
}

// MARK: - Boundary & Edge Cases

@Suite("BiquadMath — Boundary & Edge Cases (Adversarial)")
struct BiquadMathBoundaryTests {

    @Test("coefficientsForAllBands: Bluetooth HFP rate (8kHz) bypasses bands >= Nyquist")
    func bluetoothHFPBypass() {
        let gains: [Float] = Array(repeating: 12.0, count: 10)
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 8000)
        // Nyquist = 4000 Hz. Bands: 31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
        // Bands 7 (4kHz), 8 (8kHz), 9 (16kHz) >= Nyquist -> unity bypass
        for band in 7...9 {
            let o = band * 5
            #expect(coeffs[o] == 1.0 && coeffs[o+1] == 0.0 && coeffs[o+2] == 0.0
                    && coeffs[o+3] == 0.0 && coeffs[o+4] == 0.0,
                    "Band \(band) must be unity-bypassed at 8kHz sample rate")
        }
        // Bands 0-6 must NOT be bypassed (active EQ processing)
        for band in 0...6 {
            let o = band * 5
            #expect(coeffs[o] != 1.0 || coeffs[o+1] != 0.0,
                    "Band \(band) should be active at 8kHz sample rate")
        }
    }

    @Test("coefficientsForAllBands: very low sample rate (4kHz) bypasses most bands")
    func veryLowSampleRateBypass() {
        let gains: [Float] = Array(repeating: 6.0, count: 10)
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 4000)
        // Nyquist = 2000 Hz. Bands 6 (2kHz) through 9 >= Nyquist -> bypassed
        for band in 6...9 {
            let o = band * 5
            #expect(coeffs[o] == 1.0, "Band \(band) should be bypassed at 4kHz sr")
        }
        // Bands 0-5 should be active
        for band in 0...5 {
            let o = band * 5
            #expect(coeffs[o] != 1.0 || coeffs[o+1] != 0.0,
                    "Band \(band) should be active at 4kHz sr")
        }
    }

    @Test("coefficientsForAutoEQFilters: filter above Nyquist bypassed with unity")
    func autoEQNyquistBypass() {
        let filters = [
            AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 6, q: 1.4),
            AutoEQFilter(type: .peaking, frequency: 30000, gainDB: 6, q: 1.4),
        ]
        let coeffs = BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: 48000)
        #expect(coeffs.count == 10)
        // First filter: active (1kHz < 24kHz Nyquist)
        #expect(coeffs[0] != 1.0 || coeffs[1] != 0.0, "1kHz filter should be active")
        // Second filter: unity bypass (30kHz > 24kHz Nyquist)
        #expect(coeffs[5] == 1.0 && coeffs[6] == 0.0 && coeffs[7] == 0.0,
                "30kHz filter should be unity-bypassed")
    }

    @Test("coefficientsForAutoEQFilters: pre-warp producing negative frequency is bypassed")
    func preWarpNegativeFrequencyBypass() {
        // 23000 Hz > source Nyquist (22050 Hz at 44100), so pre-warp produces negative frequency
        let filters = [
            AutoEQFilter(type: .peaking, frequency: 23000, gainDB: 3, q: 1.0),
        ]
        let coeffs = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: 48000, profileOptimizedRate: 44100
        )
        #expect(coeffs[0] == 1.0 && coeffs[1] == 0.0,
                "Pre-warp of above-source-Nyquist frequency should produce unity bypass")
    }

    @Test("coefficientsForAutoEQFilters: empty filter list returns empty array")
    func autoEQEmptyFilters() {
        let coeffs = BiquadMath.coefficientsForAutoEQFilters([], sampleRate: 48000)
        #expect(coeffs.isEmpty)
    }

    @Test("coefficientsForAutoEQFilters: mixed filter types all produce stable coefficients")
    func autoEQMixedTypes() {
        let filters = [
            AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: -5.4, q: 0.7),
            AutoEQFilter(type: .peaking, frequency: 400, gainDB: 3.2, q: 2.0),
            AutoEQFilter(type: .peaking, frequency: 2000, gainDB: -4.1, q: 1.5),
            AutoEQFilter(type: .peaking, frequency: 6300, gainDB: 2.8, q: 3.0),
            AutoEQFilter(type: .highShelf, frequency: 10000, gainDB: -3.5, q: 0.7),
        ]
        let coeffs = BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: 48000)
        #expect(coeffs.count == 25)
        for i in 0..<5 {
            let a1 = coeffs[i * 5 + 3], a2 = coeffs[i * 5 + 4]
            #expect(abs(a2) < 1.0, "Filter \(i) unstable: |a2|=\(abs(a2))")
            #expect(1.0 + a1 + a2 > -1e-10, "Filter \(i) Jury f(1)=\(1.0 + a1 + a2)")
            #expect(1.0 - a1 + a2 > -1e-10, "Filter \(i) Jury f(-1)=\(1.0 - a1 + a2)")
        }
    }

    @Test("coefficientsForAutoEQFilters: no pre-warp when rates differ by < 1 Hz")
    func noPreWarpWhenRatesClose() {
        let filters = [AutoEQFilter(type: .peaking, frequency: 5000, gainDB: 6, q: 1.4)]
        let exact = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: 48000, profileOptimizedRate: 48000
        )
        let close = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: 48000, profileOptimizedRate: 48000.5
        )
        for i in 0..<5 {
            #expect(exact[i] == close[i],
                    "Coefficient \(i) should be identical when rates differ by < 1 Hz")
        }
    }

    @Test("coefficientsForAutoEQFilters: pre-warp changes coefficients when rates differ")
    func preWarpChangesCoefficients() {
        let filters = [AutoEQFilter(type: .peaking, frequency: 5000, gainDB: 6, q: 1.4)]
        let noWarp = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: 48000, profileOptimizedRate: 48000
        )
        let withWarp = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: 48000, profileOptimizedRate: 44100
        )
        #expect(noWarp[1] != withWarp[1],
                "Pre-warp should produce different b1 for 48kHz vs 44.1kHz source")
    }

    @Test("preWarpFrequency: round-trip preserves frequency (forward then inverse)")
    func preWarpRoundTrip() {
        let freq = 5000.0, r1 = 44100.0, r2 = 96000.0
        let warped = BiquadMath.preWarpFrequency(freq, from: r1, to: r2)
        let roundTrip = BiquadMath.preWarpFrequency(warped, from: r2, to: r1)
        #expect(abs(roundTrip - freq) < 0.01,
                "Round-trip should preserve frequency: \(freq) -> \(warped) -> \(roundTrip)")
    }

    @Test("preWarpFrequency: upsampling shifts frequency upward, downsampling shifts down")
    func preWarpDirectionality() {
        let freq = 5000.0
        let up = BiquadMath.preWarpFrequency(freq, from: 44100, to: 96000)
        let down = BiquadMath.preWarpFrequency(freq, from: 96000, to: 44100)
        #expect(up > freq, "Upsampling should shift frequency up: \(up)")
        #expect(down < freq, "Downsampling should shift frequency down: \(down)")
    }

    @Test("preWarpFrequency: near source Nyquist maps below target Nyquist")
    func preWarpNearNyquist() {
        let sourceRate = 44100.0, targetRate = 48000.0
        let nearNyquist = sourceRate / 2.0 - 1.0  // 22049 Hz
        let warped = BiquadMath.preWarpFrequency(nearNyquist, from: sourceRate, to: targetRate)
        #expect(warped > 0 && warped.isFinite, "Pre-warped should be finite positive")
        #expect(warped < targetRate / 2.0, "Should be below target Nyquist")
    }

    @Test("coefficientsForAllBands: all flat gains produce near-unity b0 for each band")
    func allFlatGainsNearUnity() {
        let gains: [Float] = Array(repeating: 0, count: 10)
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        for band in 0..<10 {
            #expect(abs(coeffs[band * 5] - 1.0) < 1e-10,
                    "Band \(band) b0 should be 1.0 at flat gain")
        }
    }
}
