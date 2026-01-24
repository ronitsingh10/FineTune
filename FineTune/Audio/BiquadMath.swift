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
        // Note: vDSP uses difference equation y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] + a1*y[n-1] + a2*y[n-2]
    }

    /// Compute low-shelf composite biquad coefficients
    /// Returns [b0, b1, b2, a1, a2] normalized by a0
    static func lowShelfCoefficients(
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
        let sqrtA = sqrt(A)
        
        // RBJ Low Shelf Coefficients
        let b0 =       A * ((A + 1.0) - (A - 1.0) * cosW + 2.0 * sqrtA * alpha)
        let b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW)
        let b2 =       A * ((A + 1.0) - (A - 1.0) * cosW - 2.0 * sqrtA * alpha)
        let a0 =           (A + 1.0) + (A - 1.0) * cosW + 2.0 * sqrtA * alpha
        let a1 =  -2.0 * ( (A - 1.0) + (A + 1.0) * cosW)
        let a2 =           (A + 1.0) + (A - 1.0) * cosW - 2.0 * sqrtA * alpha
        
        return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
    }

    /// Compute high-shelf composite biquad coefficients
    static func highShelfCoefficients(
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
        let sqrtA = sqrt(A)

        // RBJ High Shelf Coefficients
        let b0 =       A * ((A + 1.0) + (A - 1.0) * cosW + 2.0 * sqrtA * alpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW)
        let b2 =       A * ((A + 1.0) + (A - 1.0) * cosW - 2.0 * sqrtA * alpha)
        let a0 =           (A + 1.0) - (A - 1.0) * cosW + 2.0 * sqrtA * alpha
        let a1 =    2.0 * ((A - 1.0) - (A + 1.0) * cosW)
        let a2 =           (A + 1.0) - (A - 1.0) * cosW - 2.0 * sqrtA * alpha
        
        return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]

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
