import Foundation

enum LoudnessEqualizerMath {

    // MARK: - Fast Approximations (RT-safe, used in per-sample processing)

    /// Fast base-2 logarithm using IEEE 754 bit manipulation.
    ///
    /// Extracts the exponent and mantissa from the float's binary representation,
    /// then applies a 2nd-order minimax polynomial for `log2(1+f)` on `[0, 1)`.
    /// Maximum error: ~0.008 in log2 units ≈ 0.05 dB for `linearToDb`.
    ///
    /// - Precondition: `x > 0`. Caller must guard against zero/negative inputs.
    @inline(__always)
    private static func fastLog2(_ x: Float) -> Float {
        let bits = x.bitPattern
        let e = Float(Int32(bits >> 23) - 127)
        // Reconstitute mantissa as a float in [1, 2), then subtract 1 → f in [0, 1)
        let f = Float(bitPattern: (bits & 0x007F_FFFF) | 0x3F80_0000) - 1.0
        // Minimax polynomial for log2(1 + f) on [0, 1)
        // Constrained to pass through (0, 0) and (1, 1) exactly.
        // Max absolute error < 0.009 across the interval.
        return e + f * (1.3494295 + f * -0.3494295)
    }

    /// Fast 2^x approximation using IEEE 754 bit construction + polynomial.
    ///
    /// Splits `x` into integer part `n` (sets exponent bits) and fractional part `f`
    /// (tuned 3rd-order minimax-adjusted polynomial for `2^f`). Exact at integer inputs.
    /// Maximum error: ~0.6% amplitude ≈ 0.05 dB.
    ///
    /// - Parameter x: Exponent value. Clamped to `[-126, 126]` to avoid overflow.
    @inline(__always)
    private static func fastPow2(_ x: Float) -> Float {
        let clipped = max(min(x, 126.0), -126.0)
        let floorVal = floor(clipped)
        let n = Int32(floorVal)
        let f = clipped - floorVal
        // Tuned 3rd-order polynomial for 2^f on [0, 1)
        // Coeffs adjusted from Taylor series (e.g. 0.0558016 vs ln³2/6 ≈ 0.0555041)
        // to minimize error at the f=1 boundary, ensuring smooth transitions.
        let pow2f = 1.0 + f * (0.6931472 + f * (0.2402265 + f * 0.0558016))
        // Construct 2^n via IEEE 754 exponent field
        let bits = UInt32(bitPattern: n + 127) << 23
        return Float(bitPattern: bits) * pow2f
    }

    // MARK: - dB / Linear Conversions

    /// Convert dB to linear amplitude using fast 2^x approximation.
    ///
    /// `10^(db/20) = 2^(db / (20·log10(2))) = 2^(db · 0.16609640)`
    ///
    /// Maximum error: ~0.05 dB. Exact at 0 dB (returns 1.0).
    @inline(__always)
    static func dbToLinear(_ db: Float) -> Float {
        // 1 / (20 · log10(2)) = 1 / 6.0205999 = 0.16609640
        fastPow2(db * 0.16609640)
    }

    /// Convert linear amplitude to dB using fast log2 approximation.
    ///
    /// `20·log10(x) = (20/log2(10))·log2(x) = 6.0206·log2(x)`
    ///
    /// Maximum error: ~0.05 dB. Clamps input to ≥ 1e-9 (≈ -180 dB floor).
    @inline(__always)
    static func linearToDb(_ linear: Float) -> Float {
        // 20 / log2(10) = 20 / 3.321928 = 6.0205999
        6.0205999 * fastLog2(max(linear, 1e-9))
    }

    /// Convert mean-square power to dB using fast log2 approximation.
    ///
    /// `10·log10(x) = (10/log2(10))·log2(x) = 3.0103·log2(x)`
    ///
    /// Maximum error: ~0.03 dB. Clamps input to ≥ 1e-12 (≈ -120 dB floor).
    @inline(__always)
    static func meanSquareToDb(_ meanSquare: Float) -> Float {
        // 10 / log2(10) = 10 / 3.321928 = 3.0103000
        3.0103000 * fastLog2(max(meanSquare, 1e-12))
    }

    // MARK: - Utilities (unchanged)

    static func rmsFromMeanSquare(_ meanSquare: Float) -> Float {
        sqrt(max(meanSquare, 0))
    }

    @inline(__always)
    static func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.min(Swift.max(value, min), max)
    }

    /// Compute one-pole filter coefficient from time constant.
    /// Used only during init (not in RT path), so standard `exp` is fine.
    static func timeConstantCoefficient(timeMs: Float, stepMs: Float) -> Float {
        1 - exp(-stepMs / max(timeMs, 1e-6))
    }
}
