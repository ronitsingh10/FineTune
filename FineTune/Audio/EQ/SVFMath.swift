import Foundation

/// Audio EQ Cookbook SVF coefficient calculations
/// Reference: Andrew Simper / Cytomic's SVF equations
enum SVFMath {
    /// Standard Q for graphic EQ (overlapping bands)
    static let graphicEQQ: Double = 1.4

    /// Compute peaking bell EQ SVF coefficients
    /// Reference: https://www.kvraudio.com/forum/viewtopic.php?p=6382460#p6382460
    /// Returns [a1, a2, a3, m0, m1, m2] for SVF function
    static func peakingEQCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let G = tan(.pi * frequency / sampleRate)
        let K = 1.0 / (q * A)

        let a1 = 1.0 / (1.0 + G * (G + K))
        let a2 = G * a1
        let a3 = G * a2
        let m0 = 1.0
        let m1 = K * (A * A - 1.0)
        let m2 = 0.0

        return [ a1, a2, a3, m0, m1, m2 ]
    }

    /// Compute low shelf SVF coefficients
    /// Reference: https://www.kvraudio.com/forum/viewtopic.php?p=6382460#p6382460
    /// Returns [a1, a2, a3, m0, m1, m2] for SVF function
    static func lowShelfCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let G = tan(.pi * frequency / sampleRate) / sqrt(A)
        let K = 1.0 / q

        let a1 = 1.0 / (1.0 + G * (G + K))
        let a2 = G * a1
        let a3 = G * a2
        let m0 = 1.0
        let m1 = K * (A - 1.0)
        let m2 = (A * A - 1.0)

        return [ a1, a2, a3, m0, m1, m2 ]
    }

    /// Compute high shelf SVF coefficients
    /// Reference: https://www.kvraudio.com/forum/viewtopic.php?p=6382460#p6382460
    /// Returns [a1, a2, a3, m0, m1, m2] for SVF function
    static func highShelfCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let G = tan(.pi * frequency / sampleRate) * sqrt(A)
        let K = 1.0 / q

        let a1 = 1.0 / (1.0 + G * (G + K))
        let a2 = G * a1
        let a3 = G * a2
        let m0 = A * A
        let m1 = K * (1.0 - A) * A
        let m2 = (1 - A * A)

        return [ a1, a2, a3, m0, m1, m2 ]
    }

    /// Correct a filter frequency optimized at `sourceRate` for use at `targetRate`.
    /// Uses inverse bilinear transform (digital→analog) then forward (analog→digital).
    static func preWarpFrequency(
        _ freq: Double,
        from sourceRate: Double,
        to targetRate: Double
    ) -> Double {
        // Map from source digital domain to analog (undo source bilinear transform)
        let fAnalog = (sourceRate / .pi) * tan(.pi * freq / sourceRate)
        // Map from analog to target digital domain (apply target bilinear transform)
        return (targetRate / .pi) * atan(.pi * fAnalog / targetRate)
    }

    /// Compute coefficients for AutoEQ filters (peaking, lowShelf, highShelf).
    /// Returns flat array of 6*N Doubles for SVF function
    ///
    /// - Parameters:
    ///   - filters: Filter parameters from an AutoEQ profile.
    ///   - sampleRate: Device's actual sample rate (Hz).
    ///   - profileOptimizedRate: Sample rate the profile was optimized for (Hz).
    ///     When different from `sampleRate`, filter frequencies are pre-warped to
    ///     compensate for the bilinear transform's frequency warping.
    static func coefficientsForAutoEQFilters(
        _ filters: [AutoEQFilter],
        sampleRate: Double,
        profileOptimizedRate: Double = 48000
    ) -> [Double] {
        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(filters.count * 5)

        let needsPreWarp = abs(profileOptimizedRate - sampleRate) > 1.0

        for filter in filters {
            var frequency = filter.frequency

            // Pre-warp frequency if profile was optimized for a different sample rate
            if needsPreWarp {
                frequency = preWarpFrequency(frequency, from: profileOptimizedRate, to: sampleRate)
            }

            // Bypass invalid or above-Nyquist filters (pre-warp can produce
            // negative frequencies when the source filter is above its own Nyquist)
            if frequency <= 0 || frequency >= sampleRate / 2.0 {
                allCoeffs.append(contentsOf: [0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
                continue
            }

            let coeffs: [Double]
            switch filter.type {
            case .peaking:
                coeffs = peakingEQCoefficients(
                    frequency: frequency, gainDB: filter.gainDB,
                    q: filter.q, sampleRate: sampleRate)
            case .lowShelf:
                coeffs = lowShelfCoefficients(
                    frequency: frequency, gainDB: filter.gainDB,
                    q: filter.q, sampleRate: sampleRate)
            case .highShelf:
                coeffs = highShelfCoefficients(
                    frequency: frequency, gainDB: filter.gainDB,
                    q: filter.q, sampleRate: sampleRate)
            }
            allCoeffs.append(contentsOf: coeffs)
        }

        return allCoeffs
    }

    /// Compute coefficients for all 10 bands
    /// Returns 60 Doubles: [band0: a1,a2,a3,m0,m1,m2, band1: ..., ...]
    static func coefficientsForAllBands(
        gains: [Float],
        sampleRate: Double
    ) -> [Double] {
        guard gains.count == EQSettings.bandCount else {
            // Return unity (passthrough) coefficients for all bands
            return (0..<EQSettings.bandCount).flatMap { _ in [0.0, 0.0, 0.0, 1.0, 0.0, 0.0] }
        }

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(60)

        for (index, frequency) in EQSettings.frequencies.enumerated() {
            // Bands at or above Nyquist cannot exist in the signal — bypass with unity gain.
            if frequency >= sampleRate / 2.0 {
                allCoeffs.append(contentsOf: [0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
                continue
            }
            let bandCoeffs = peakingEQCoefficients(
                frequency: frequency,
                gainDB: gains[index],
                q: graphicEQQ,
                sampleRate: sampleRate
            )
            allCoeffs.append(contentsOf: bandCoeffs)
        }

        return allCoeffs
    }
}
