import Foundation

/// Audio EQ Cookbook biquad coefficient calculations
/// Reference: Robert Bristow-Johnson's Audio EQ Cookbook
enum BiquadMath {
    /// Standard Q for graphic EQ (overlapping bands)
    static let graphicEQQ: Double = 1.4

    /// Compute peaking EQ biquad coefficients
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func peakingEQCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosW
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha / A

        // Normalize by a0 for vDSP_biquad format
        // vDSP difference equation: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
        // Coefficients are passed as-is (vDSP internally subtracts a1/a2)
        return [
            b0 / a0,
            b1 / a0,
            b2 / a0,
            a1 / a0,
            a2 / a0
        ]
    }

    /// Compute coefficients for all 10 bands
    /// Returns 50 Doubles: [band0: b0,b1,b2,a1,a2, band1: ..., ...]
    static func coefficientsForAllBands(
        gains: [Float],
        sampleRate: Double
    ) -> [Double] {
        precondition(gains.count == EQSettings.bandCount)

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(50)

        for (index, frequency) in EQSettings.frequencies.enumerated() {
            // Bands at or above Nyquist cannot exist in the signal — bypass with unity gain.
            // Without this guard, omega > pi produces negative alpha, yielding unstable
            // biquad coefficients (poles outside the unit circle) that cause exponentially
            // growing output heard as robotic/static distortion.
            if frequency >= sampleRate / 2.0 {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
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

    /// Compute coefficients for arbitrary parametric filters.
    /// Returns flattened [b0,b1,b2,a1,a2] per filter section for vDSP_biquad.
    static func coefficientsForParametricFilters(
        filters: [HeadphoneEQFilter],
        sampleRate: Double
    ) -> [Double] {
        guard !filters.isEmpty else { return [] }

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(filters.count * 5)

        for filter in filters {
            guard filter.frequencyHz > 0, filter.q > 0 else { continue }

            // Filter sections at/above Nyquist are bypassed.
            if filter.frequencyHz >= sampleRate / 2.0 {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }

            let coeffs = peakingEQCoefficients(
                frequency: filter.frequencyHz,
                gainDB: filter.gainDB,
                q: filter.q,
                sampleRate: sampleRate
            )
            allCoeffs.append(contentsOf: coeffs)
        }

        return allCoeffs
    }
}
