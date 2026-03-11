// FineTune/Audio/SoftLimiter.swift
import Accelerate

/// RT-safe soft-knee limiter using asymptotic compression.
/// Prevents harsh clipping when audio is boosted above unity gain.
///
/// **RT-safety:** All methods are pure arithmetic with no allocation, locks, or I/O.
/// `processBuffer()` uses vDSP_maxmgv for fast peak detection (skips processing
/// when the entire buffer is below threshold).
///
/// **Behavior:**
/// - Below 0.95: passes through unchanged (transparent)
/// - Above 0.95: smooth compression approaching 1.0 asymptotically
/// - Never exceeds ±1.0 for any finite input
enum SoftLimiter {

    /// Threshold where limiting begins (below this, audio passes through)
    static let threshold: Float = 0.95

    /// Maximum output level (asymptotic ceiling)
    static let ceiling: Float = 1.0

    /// Available headroom above threshold
    @inline(__always)
    static var headroom: Float { ceiling - threshold }  // 0.05

    /// Applies soft-knee limiting to a single sample.
    ///
    /// Formula: output = threshold + headroom * (overshoot / (overshoot + headroom))
    /// As overshoot -> infinity, output -> ceiling asymptotically.
    ///
    /// - Parameter sample: Input sample (may exceed ±1.0 when boosted)
    /// - Returns: Limited sample, guaranteed <= ±ceiling for any finite input
    @inline(__always)
    static func apply(_ sample: Float) -> Float {
        let absSample = abs(sample)

        // Below threshold: pass through unchanged
        if absSample <= threshold {
            return sample
        }

        // Above threshold: asymptotic compression
        let overshoot = absSample - threshold
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))

        return sample >= 0 ? compressed : -compressed
    }

    /// Applies soft limiting to an entire buffer of interleaved stereo samples.
    ///
    /// Uses vDSP_maxmgv as a fast path: if the buffer peak is at or below threshold,
    /// the entire buffer is skipped (zero per-sample overhead for normal-level audio).
    ///
    /// - Parameters:
    ///   - buffer: Pointer to interleaved Float32 samples (modified in-place)
    ///   - sampleCount: Total number of samples (frames * channels)
    @inline(__always)
    static func processBuffer(_ buffer: UnsafeMutablePointer<Float>, sampleCount: Int) {
        // Fast path: if peak is at or below threshold, no limiting needed
        var bufferPeak: Float = 0
        vDSP_maxmgv(buffer, 1, &bufferPeak, vDSP_Length(sampleCount))
        guard bufferPeak > threshold else { return }

        for i in 0..<sampleCount {
            buffer[i] = apply(buffer[i])
        }
    }
}
