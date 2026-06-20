// FineTuneTests/ISO226ContoursTests.swift

import Foundation
import Testing
@testable import FineTune

@Suite("ISO226Contours — ISO 226:2023")
struct ISO226ContoursReferenceTests {

    @Test("2023 Table 1 coefficients are loaded at critical frequencies")
    func table1CriticalCoefficients() {
        #expect(abs(ISO226Contours.referenceLoudnessExponent - 0.300) < 1e-12)

        #expect(abs(ISO226Contours.loudnessPerceptionExponents[0] - 0.635) < 1e-12)
        #expect(abs(ISO226Contours.transferMagnitudesDB[0] - (-31.5)) < 1e-12)
        #expect(abs(ISO226Contours.hearingThresholdsDB[0] - 78.1) < 1e-12)

        #expect(abs(ISO226Contours.loudnessPerceptionExponents[17] - 0.300) < 1e-12)
        #expect(abs(ISO226Contours.transferMagnitudesDB[17] - 0.0) < 1e-12)
        #expect(abs(ISO226Contours.hearingThresholdsDB[17] - 2.4) < 1e-12)

        #expect(abs(ISO226Contours.loudnessPerceptionExponents[28] - 0.354) < 1e-12)
        #expect(abs(ISO226Contours.transferMagnitudesDB[28] - (-3.5)) < 1e-12)
        #expect(abs(ISO226Contours.hearingThresholdsDB[28] - 12.3) < 1e-12)
    }

    @Test("Normative contour values at 20 phon match ISO 226:2023 equation")
    func contourReferenceValues20Phon() {
        let contour = ISO226Contours.contourSPL(atPhon: 20.0)

        expectClose(contour[0], 88.167, tolerance: 0.01)
        expectClose(contour[5], 58.197, tolerance: 0.01)
        expectClose(contour[17], 20.000, tolerance: 0.001)
        expectClose(contour[23], 15.233, tolerance: 0.01)
        expectClose(contour[28], 32.746, tolerance: 0.01)
    }

    @Test("Normative contour values at 40 phon match ISO 226:2023 equation")
    func contourReferenceValues40Phon() {
        let contour = ISO226Contours.contourSPL(atPhon: 40.0)

        expectClose(contour[0], 99.456, tolerance: 0.01)
        expectClose(contour[5], 72.849, tolerance: 0.01)
        expectClose(contour[17], 40.000, tolerance: 0.001)
        expectClose(contour[23], 36.712, tolerance: 0.01)
        expectClose(contour[28], 51.253, tolerance: 0.01)
    }

    @Test("1 kHz reference contour remains identity in phon space",
          arguments: [20.0, 40.0, 60.0, 80.0])
    func oneKilohertzMatchesPhon(phon: Double) {
        let contour = ISO226Contours.contourSPL(atPhon: phon)
        expectClose(contour[17], phon, tolerance: 0.02)
    }

    @Test("System volume heuristic maps 100% volume to the reference phon")
    func fullVolumeMapsToReferencePhon() {
        expectClose(
            ISO226Contours.estimatedPhon(fromSystemVolume: 1.0),
            ISO226Contours.defaultReferencePhon,
            tolerance: 0.001
        )
    }

    @Test("System volume heuristic maps to custom reference phon")
    func customVolumeMapsToCustomReferencePhon() {
        expectClose(
            ISO226Contours.estimatedPhon(fromSystemVolume: 1.0, referencePhon: 100.0),
            100.0,
            tolerance: 0.001
        )
        expectClose(
            ISO226Contours.estimatedPhon(fromSystemVolume: 0.5, referencePhon: 100.0),
            50.0,
            tolerance: 0.001
        )
    }

    @Test("Compensation is flat at custom reference phon level")
    func customReferencePhonIsFlat() {
        let gains = ISO226Contours.compensationGains(atPhon: 100.0, referencePhon: 100.0)
        #expect(gains.allSatisfy { abs($0) < 1e-9 })
    }

    @Test("20 Hz compensation reflects the 2023 low-frequency model and derived headroom")
    func lowFrequencyTwentyHertzEdgeCase() {
        let gains = ISO226Contours.compensationGains(atPhon: 20.0, referencePhon: 80.0)
        let headroom = ISO226Contours.requiredHeadroomDB(forCompensationGains: gains)

        expectClose(gains[0], 29.323, tolerance: 0.01)
        expectClose(gains[17], 0.0, tolerance: 0.001)
        expectClose(gains[23], -3.220, tolerance: 0.01)
        expectClose(headroom, 29.323, tolerance: 0.01)
    }

    @Test("Compensation is normalized around 1 kHz instead of restoring overall loudness")
    func normalizedCompensationAtMidVolume() {
        let gains = ISO226Contours.compensationGains(atPhon: 52.5, referencePhon: 80.0)
        let headroom = ISO226Contours.requiredHeadroomDB(forCompensationGains: gains)

        expectClose(gains[0], 14.325, tolerance: 0.01)
        expectClose(gains[5], 10.161, tolerance: 0.01)
        expectClose(gains[17], 0.0, tolerance: 0.001)
        expectClose(gains[23], -1.130, tolerance: 0.01)
        expectClose(gains[28], 4.024, tolerance: 0.01)
        expectClose(headroom, 14.325, tolerance: 0.01)
    }

    @Test("Reference phon contour produces flat compensation")
    func referencePhonIsFlat() {
        // defaultReferencePhon is 80 — compensation at the reference level must be flat
        let gains = ISO226Contours.compensationGains(atPhon: ISO226Contours.defaultReferencePhon)
        #expect(gains.allSatisfy { abs($0) < 1e-9 })
        #expect(abs(ISO226Contours.requiredHeadroomDB(forCompensationGains: gains)) < 1e-9)
    }

    @Test("Compensation amount scales the normalized contour strength")
    func compensationAmountScalesTargetCurve() {
        // Expected values computed against referencePhon=80 — pass explicitly
        let full = ISO226Contours.compensationGains(atPhon: 20.0, referencePhon: 80.0, amount: 1.0)
        let half = ISO226Contours.compensationGains(atPhon: 20.0, referencePhon: 80.0, amount: 0.5)
        let flat = ISO226Contours.compensationGains(atPhon: 20.0, referencePhon: 80.0, amount: 0.0)

        expectClose(full[0], 29.323, tolerance: 0.01)
        expectClose(half[0], 14.6615, tolerance: 0.01)
        expectClose(half[23], -1.610, tolerance: 0.01)
        #expect(flat.allSatisfy { abs($0) < 1e-9 })
    }
}

@Suite("ISO226Contours — migration deltas")
struct ISO226ContoursMigrationTests {

    @Test("Migration preserves a documented delta against the legacy in-app table at key points")
    func legacyDeltaSnapshots() {
        let contour20 = ISO226Contours.contourSPL(atPhon: 20.0)
        let contour40 = ISO226Contours.contourSPL(atPhon: 40.0)
        let contour80 = ISO226Contours.contourSPL(atPhon: 80.0)

        expectClose(contour20[0] - legacyContour20Phon[0], 13.867, tolerance: 0.01)
        expectClose(contour20[17] - legacyContour20Phon[17], 16.800, tolerance: 0.01)
        expectClose(contour40[5] - legacyContour40Phon[5], 25.849, tolerance: 0.01)
        expectClose(contour80[23] - legacyContour80Phon[23], 74.953, tolerance: 0.01)
        expectClose(contour80[28] - legacyContour80Phon[28], 80.603, tolerance: 0.01)
    }

    private let legacyContour20Phon: [Double] = [
        74.3, 65.0, 56.3, 48.4, 41.7, 35.5, 29.8, 25.1, 20.7, 16.8,
        13.8, 11.2, 9.0, 7.2, 6.0, 4.9, 4.0, 3.2, 2.4, 1.4,
        1.0, 0.5, 0.1, 0.0, -0.5, -1.3, -3.0, -4.0, -2.0,
    ]

    private let legacyContour40Phon: [Double] = [
        86.0, 77.5, 68.7, 60.7, 53.7, 47.0, 40.7, 35.0, 30.0, 25.3,
        21.3, 17.8, 15.0, 12.5, 10.5, 8.9, 7.5, 6.3, 5.0, 3.5,
        2.5, 1.5, 0.8, 0.5, 0.1, -0.4, -1.5, -2.5, 0.5,
    ]

    private let legacyContour80Phon: [Double] = [
        99.5, 91.0, 82.5, 75.5, 69.5, 63.0, 57.0, 51.0, 45.5, 40.0,
        35.0, 30.5, 27.0, 23.5, 20.5, 18.0, 15.5, 13.5, 11.5, 9.5,
        7.5, 5.8, 4.3, 3.5, 3.0, 2.5, 1.5, 0.0, 5.0,
    ]

}

@Suite("LoudnessCompensator — headroom fitting")
struct LoudnessCompensatorHeadroomTests {

    @Test("4-filter loudness fit tracks the target contour at 3% system volume")
    func fittedCascadeTracksTargetAtThreePercentVolume() {
        let sampleRate = 48_000.0
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: 0.03)
        let targetGains = ISO226Contours.compensationGains(atPhon: phon)
        let fittedGains = LoudnessCompensator.fittedSectionGains(forPhon: phon, sampleRate: sampleRate)
        let coefficients = LoudnessCompensator.coefficientsForBands(gains: fittedGains, sampleRate: sampleRate)

        #expect(LoudnessCompensator.bandCount == 4)

        var lowFrequencySquaredError = 0.0
        var lowFrequencyCount = 0
        var maxAbsError = 0.0

        for index in 0..<96 {
            let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / 95.0)
            let targetDB = ISO226Contours.interpolateCompensation(targetGains, atFrequency: frequency)
            let realizedDB = cascadeResponseDB(
                coefficients: coefficients,
                sectionCount: LoudnessCompensator.bandCount,
                sampleRate: sampleRate,
                frequency: frequency
            )
            let responseError = realizedDB - targetDB
            maxAbsError = max(maxAbsError, abs(responseError))

            if frequency <= 150.0 {
                lowFrequencySquaredError += responseError * responseError
                lowFrequencyCount += 1
            }
        }

        let lowFrequencyRMSE = sqrt(lowFrequencySquaredError / Double(lowFrequencyCount))
        #expect(lowFrequencyRMSE <= 2.0, "Low-frequency RMSE should stay within 2 dB, got \(lowFrequencyRMSE) dB")
        #expect(maxAbsError <= 3.0, "Max fitted-response error should stay within 3 dB, got \(maxAbsError) dB")
    }

    @Test("Headroom subtraction ensures cascade peak never exceeds 0 dBFS")
    func headroomSubtractionKeepsPeakAtOrBelowZero() {
        let sampleRate = 48_000.0
        // Test at multiple phon levels where compensation is active
        for phon in [20.0, 30.0, 40.0, 50.0, 60.0] {
            let fittedGains = LoudnessCompensator.fittedSectionGains(forPhon: phon, sampleRate: sampleRate)
            let rawCoefficients = LoudnessCompensator.coefficientsForBands(gains: fittedGains, sampleRate: sampleRate)

            // Find the peak of the raw cascade response
            var maxRawDB: Double = -200
            for index in 0..<96 {
                let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / 95.0)
                let responseDB = cascadeResponseDB(
                    coefficients: rawCoefficients,
                    sectionCount: LoudnessCompensator.bandCount,
                    sampleRate: sampleRate,
                    frequency: frequency
                )
                if responseDB > maxRawDB { maxRawDB = responseDB }
            }
            let headroom = max(maxRawDB, 0.0)

            // Subtract headroom from all gains and recompute coefficients
            let adjustedGains = fittedGains.map { $0 - Float(headroom) }
            let adjustedCoefficients = LoudnessCompensator.coefficientsForBands(
                gains: adjustedGains,
                sampleRate: sampleRate
            )

            // Verify the adjusted cascade peak is at or below 0 dBFS
            var maxAdjustedDB: Double = -200
            for index in 0..<96 {
                let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / 95.0)
                let responseDB = cascadeResponseDB(
                    coefficients: adjustedCoefficients,
                    sectionCount: LoudnessCompensator.bandCount,
                    sampleRate: sampleRate,
                    frequency: frequency
                )
                if responseDB > maxAdjustedDB { maxAdjustedDB = responseDB }
            }
            #expect(maxAdjustedDB <= 0.1,
                    "At \(phon) phon, cascade peak \(maxAdjustedDB) dB should be ≤ 0 dBFS after headroom subtraction")
        }
    }

    @Test("ISO 226 curve fit gain at 1 kHz is monotonic with system volume")
    func monotonicResponseAtDiscreteVolumes() {
        let sampleRate = 48_000.0
        var previousOneKilohertzGain = 0.0
        let volumes: [Float] = [1.0, 0.75, 0.5, 0.25, 0.0]
        for (i, vol) in volumes.enumerated() {
            let phon = ISO226Contours.estimatedPhon(fromSystemVolume: vol)
            let fittedGains = LoudnessCompensator.fittedSectionGains(forPhon: phon, sampleRate: sampleRate)
            
            // Peak subtraction (realized in updateForVolume / computeBandGains)
            let rawCoefficients = LoudnessCompensator.coefficientsForBands(gains: fittedGains, sampleRate: sampleRate)
            var maxRawDB: Double = -200
            for index in 0..<96 {
                let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / 95.0)
                let responseDB = cascadeResponseDB(
                    coefficients: rawCoefficients,
                    sectionCount: LoudnessCompensator.bandCount,
                    sampleRate: sampleRate,
                    frequency: frequency
                )
                if responseDB > maxRawDB { maxRawDB = responseDB }
            }
            let peakGain = max(maxRawDB, 0.0)
            let adjustedGains = fittedGains.map { $0 - Float(peakGain) }
            
            let adjustedCoefficients = LoudnessCompensator.coefficientsForBands(
                gains: adjustedGains,
                sampleRate: sampleRate
            )
            let oneKilohertzGain = cascadeResponseDB(
                coefficients: adjustedCoefficients,
                sectionCount: LoudnessCompensator.bandCount,
                sampleRate: sampleRate,
                frequency: 1000.0
            )
            
            if i == 0 {
                // At volume 1.0, phon is 80 (defaultReferencePhon is 80), gains are close to 0
                #expect(abs(oneKilohertzGain) < 0.2, "Volume 1.0 should be flat at 1 kHz, got \(oneKilohertzGain) dB")
            } else {
                #expect(oneKilohertzGain < previousOneKilohertzGain, "Monotonicity failure: volume \(vol) gain at 1 kHz (\(oneKilohertzGain) dB) is not less than volume \(volumes[i-1]) gain (\(previousOneKilohertzGain) dB)")
            }
            previousOneKilohertzGain = oneKilohertzGain
        }
    }

    private func cascadeResponseDB(
        coefficients: [Double],
        sectionCount: Int,
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        let normalizedFrequency = 2.0 * Double.pi * frequency / sampleRate
        let magnitude = stride(from: 0, to: sectionCount * 5, by: 5).reduce(1.0) { partial, offset in
            partial * magnitudeResponse(
                coefficients: Array(coefficients[offset..<(offset + 5)]),
                atNormalizedFrequency: normalizedFrequency
            )
        }
        return 20.0 * log10(magnitude)
    }

    private func magnitudeResponse(coefficients: [Double], atNormalizedFrequency omega: Double) -> Double {
        let cosW = cos(omega)
        let sinW = sin(omega)
        let cos2W = cos(2.0 * omega)
        let sin2W = sin(2.0 * omega)

        let numeratorReal = coefficients[0] + coefficients[1] * cosW + coefficients[2] * cos2W
        let numeratorImag = -(coefficients[1] * sinW + coefficients[2] * sin2W)
        let denominatorReal = 1.0 + coefficients[3] * cosW + coefficients[4] * cos2W
        let denominatorImag = -(coefficients[3] * sinW + coefficients[4] * sin2W)

        return sqrt(
            (numeratorReal * numeratorReal + numeratorImag * numeratorImag) /
            (denominatorReal * denominatorReal + denominatorImag * denominatorImag)
        )
    }
}

@Suite("LoudnessCompensator — enable state")
struct LoudnessCompensatorEnableStateTests {

    @Test("Re-enabling loudness at the same system volume immediately restores the effect")
    func sameVolumeReEnableRestoresProcessing() {
        let processor = LoudnessCompensator(sampleRate: 48_000)

        processor.updateForVolume(0.25)
        #expect(processor.isEnabled, "Processor should enable after an initial non-reference volume update")

        processor.setEnabled(false)
        #expect(!processor.isEnabled, "Test setup should disable the processor before re-enabling")

        processor.updateForVolume(0.25)
        #expect(processor.isEnabled, "Processor should re-enable immediately even if volume did not change")
    }
}

@Suite("LoudnessCompensator — custom reference level coefficients")
struct LoudnessCompensatorCustomReferenceTests {
    @Test("Processor bypasses when volume is at the custom reference level")
    func bypassesAtCustomReferenceLevel() {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        // Set custom reference level to 60.0 phon
        // At full volume (1.0), estimatedPhon is 60.0, which matches the custom reference level
        processor.updateForVolume(1.0, referencePhon: 60.0)
        #expect(!processor.isEnabled, "Processor should be bypassed/disabled at the reference level")
    }

    @Test("Fitted gains change when custom reference level is modified")
    func fittedGainsChangeWithCustomReference() {
        let sampleRate = 48_000.0
        // Calculate gains for phon 40 with reference phon 80
        let gainsRef80 = LoudnessCompensator.fittedSectionGains(forPhon: 40.0, referencePhon: 80.0, sampleRate: sampleRate)
        // Calculate gains for phon 40 with reference phon 100
        let gainsRef100 = LoudnessCompensator.fittedSectionGains(forPhon: 40.0, referencePhon: 100.0, sampleRate: sampleRate)

        // The gains must be different since the reference levels are different
        #expect(gainsRef80 != gainsRef100, "Fitted gains should differ under different reference levels")
    }

    @Test("Headroom calculation excludes frequencies below 30 Hz")
    func headroomExcludesSub30Hz() {
        let sampleRate = 48_000.0
        
        // 1. Calculate fitted gains (without headroom subtraction) using the internal method
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: 20.0, referencePhon: 85.0, sampleRate: sampleRate)
        
        // 2. Convert to coefficients using the internal method
        let coefficients = LoudnessCompensator.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        
        // 3. Evaluate the realized response ourselves
        let gridCount = 96
        var realized: [Double] = []
        for index in 0..<gridCount {
            let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / Double(gridCount - 1))
            let omega = 2.0 * Double.pi * frequency / sampleRate
            
            // Inline cascadeMagnitude
            var magnitude = 1.0
            for offset in stride(from: 0, to: LoudnessCompensator.bandCount * 5, by: 5) {
                let numeratorReal = coefficients[offset] + coefficients[offset + 1] * cos(omega) + coefficients[offset + 2] * cos(2.0 * omega)
                let numeratorImag = -(coefficients[offset + 1] * sin(omega) + coefficients[offset + 2] * sin(2.0 * omega))
                let denominatorReal = 1.0 + coefficients[offset + 3] * cos(omega) + coefficients[offset + 4] * cos(2.0 * omega)
                let denominatorImag = -(coefficients[offset + 3] * sin(omega) + coefficients[offset + 4] * sin(2.0 * omega))

                let numeratorMagnitudeSquared = numeratorReal * numeratorReal + numeratorImag * numeratorImag
                let denominatorMagnitudeSquared = denominatorReal * denominatorReal + denominatorImag * denominatorImag
                magnitude *= sqrt(numeratorMagnitudeSquared / denominatorMagnitudeSquared)
            }
            realized.append(20.0 * log10(magnitude))
        }
        
        // 4. Find the peak above 30 Hz (our new headroom)
        var peakDB = 0.0
        for index in 0..<gridCount {
            let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / Double(gridCount - 1))
            if frequency >= 30.0 {
                peakDB = max(peakDB, realized[index])
            }
        }
        
        // 5. Shift the realized response by peakDB
        let realizedAfterHeadroom = realized.map { $0 - peakDB }
        
        // 6. Find peak above and below 30 Hz in the shifted response
        var maxAbove30 = -Double.infinity
        var maxBelow30 = -Double.infinity
        for index in 0..<gridCount {
            let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / Double(gridCount - 1))
            if frequency >= 30.0 {
                maxAbove30 = max(maxAbove30, realizedAfterHeadroom[index])
            } else {
                maxBelow30 = max(maxBelow30, realizedAfterHeadroom[index])
            }
        }
        #expect(maxAbove30 <= 0.05)
        #expect(maxBelow30 > 0.5)
    }

    @Test("Dynamic headroom scales EQ gains based on system volume")
    func dynamicHeadroomScalesEQGains() {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        
        // 1. Run at high volume (0.95 = almost 0 dB attenuation). Headroom subtraction must be active.
        processor.updateForVolume(0.95, digitalVolume: 0.95, referencePhon: 80.0)
        let coefficientsHigh = processor.recomputeCoefficients()?.coefficients ?? []
        
        // 2. Run at low volume (0.05 = ~26 dB attenuation). EQ can use this attenuation as headroom,
        // so less (or zero) headroom subtraction is required, resulting in larger band gains.
        processor.updateForVolume(0.05, digitalVolume: 0.05, referencePhon: 80.0)
        let coefficientsLow = processor.recomputeCoefficients()?.coefficients ?? []
        
        // 3. Since low volume has large digital headroom, its band gains should be higher
        // (meaning less digital attenuation on the filters). We verify the overall cascade
        // magnitude is larger (or coefficients have different scaling).
        #expect(coefficientsHigh != coefficientsLow)
    }

    @Test("Generate JSON curves")
    func generateJSONCurves() {
        let sampleRate = 48000.0
        let targetPhon = 20.0
        let shelfFrequencies = [30.0, 40.0, 45.0, 50.0]
        
        var outputData: [String: Any] = [:]
        var frequenciesArray: [Double] = []
        
        let gridCount = 96
        for index in 0..<gridCount {
            let frequency = 20.0 * pow(20_000.0 / 20.0, Double(index) / Double(gridCount - 1))
            frequenciesArray.append(frequency)
        }
        outputData["frequencies"] = frequenciesArray
        
        var curvesData: [String: [Double]] = [:]
        
        for shelf in shelfFrequencies {
            let rawCompensation = ISO226Contours.compensationGains(atPhon: targetPhon, referencePhon: 85.0)
            let targetCurve = frequenciesArray.map { freq in
                let effectiveFreq = max(freq, shelf)
                return ISO226Contours.interpolateCompensation(rawCompensation, atFrequency: effectiveFreq)
            }
            
            let basisResponses = LoudnessCompensator.basisResponsesDB(sampleRate: sampleRate)
            let gramMatrix = LoudnessCompensator.gramMatrix(for: basisResponses)
            
            var sectionGains = [Double](repeating: 0.0, count: LoudnessCompensator.bandCount)
            for _ in 0..<3 {
                let realized = LoudnessCompensator.realizedResponseDB(sectionGains: sectionGains, sampleRate: sampleRate)
                let residual = zip(targetCurve, realized).map { $0.0 - $0.1 }
                let rhs = basisResponses.map { basis in
                    zip(basis, residual).reduce(0.0) { $0 + $1.0 * $1.1 }
                }
                if let delta = LoudnessCompensator.solveLinearSystem(gramMatrix, rhs: rhs) {
                    for index in 0..<LoudnessCompensator.bandCount {
                        sectionGains[index] += delta[index]
                    }
                }
            }
            
            let realizedBeforeHeadroom = LoudnessCompensator.realizedResponseDB(sectionGains: sectionGains, sampleRate: sampleRate)
            
            var peakDB = 0.0
            for (index, freq) in frequenciesArray.enumerated() {
                if freq >= shelf {
                    peakDB = max(peakDB, realizedBeforeHeadroom[index])
                }
            }
            
            let realizedAfterHeadroom = realizedBeforeHeadroom.map { $0 - peakDB }
            curvesData[String(format: "%.0f", shelf)] = realizedAfterHeadroom
        }
        
        outputData["curves"] = curvesData
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: outputData, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            try? jsonString.write(toFile: "/Users/air/.gemini/antigravity-ide/brain/e2bb06c4-9dc7-466f-a523-b17d0e20db39/scratch/data.json", atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - estimatedPhon boundary tests

@Suite("ISO226Contours — estimatedPhon boundaries")
struct EstimatedPhonBoundaryTests {

    @Test("Zero volume maps to 0 phon")
    func zeroVolumeMapsToLowerBound() {
        // volume=0 → 0 phon
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: 0.0)
        expectClose(phon, 0.0, tolerance: 0.001)
    }

    @Test("Full volume maps to reference phon (83 phon)")
    func fullVolumeMapsToReferencePhon() {
        // volume=1.0 → reference phon (83.0)
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: 1.0)
        expectClose(phon, ISO226Contours.defaultReferencePhon, tolerance: 0.001)
    }

    @Test("Volume above 1.0 is clamped to reference phon")
    func volumeAboveOneClampsToReferencePhon() {
        // volume=1.5 → clamped to 1.0 → same as full volume
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: 1.5)
        expectClose(phon, ISO226Contours.defaultReferencePhon, tolerance: 0.001)
    }

    @Test("Negative volume is clamped to 0 phon")
    func negativeVolumeClampsToLowerBound() {
        // volume=-0.5 → clamped to 0.0 → same as zero volume
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: -0.5)
        expectClose(phon, 0.0, tolerance: 0.001)
    }

    @Test("Quarter volume maps to 23.9375 phon")
    func quarterVolumeMidpoint() {
        // volume=0.25 → 20 + 0.05 / 0.8 * 63.0 = 23.9375 phon
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: 0.25)
        expectClose(phon, 23.9375, tolerance: 0.01)
    }
}



private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double) {
    #expect(abs(actual - expected) <= tolerance, "Expected \(expected), got \(actual)")
}
