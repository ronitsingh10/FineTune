// FineTune/Audio/Loudness/AgcPhonOffsetSmoother.swift
import Foundation

/// Smooths AGC gain for use as a phon offset in loudness compensation.
///
/// The AGC's own time constants (6 dB/s attack, 2.7 dB/s release) are designed
/// for compression — they track individual transients. Using raw AGC gain as a
/// phon offset would cause audible bass-boost pumping with program dynamics.
///
/// This smoother adds a second, much longer time constant layer:
/// - **3 s attack** (EBU R128 Short-term loudness): tracks content-type changes
///   smoothly, ignoring individual phrases and transients.
/// - **10 s release**: humans weight louder portions more heavily (Dolby ASA
///   patent US11362631), so compensation holds during brief quiet passages.
/// - **Fast path** for large changes (>6 dB): 1 s attack / 3 s release —
///   adapts faster when AGC gain changes dramatically (e.g., source switch).
///
/// **Threading:** `process` runs on the main thread (during periodic polling).
/// `currentOffset` is read on the main thread. No RT-thread interaction.
final class AgcPhonOffsetSmoother: @unchecked Sendable {

    // MARK: - Coefficients

    /// Normal attack coefficient (3 s time constant).
    private let attackCoeff: Float
    /// Normal release coefficient (10 s time constant).
    private let releaseCoeff: Float
    /// Fast attack coefficient (1 s time constant, for large jumps).
    private let fastAttackCoeff: Float
    /// Fast release coefficient (3 s time constant, for large drops).
    private let fastReleaseCoeff: Float

    /// Threshold in dB above which the fast-path time constants are used.
    private let fastThresholdDb: Float = 6.0

    // MARK: - State

    /// Current smoothed gain value in dB.
    private var smoothedDb: Float = 0

    // MARK: - Output

    /// Current smoothed AGC gain offset in dB (always ≤ 0, since AGC is downward-only).
    var currentOffset: Float { smoothedDb }

    // MARK: - Init

    /// Create a smoother with time constants calibrated for the polling interval.
    ///
    /// - Parameter pollIntervalMs: The interval at which `process` will be called,
    ///   in milliseconds. Coefficients are computed relative to this interval.
    init(pollIntervalMs: Float = 200) {
        let stepMs = pollIntervalMs
        attackCoeff = 1 - exp(-stepMs / 3000.0)
        releaseCoeff = 1 - exp(-stepMs / 10000.0)
        fastAttackCoeff = 1 - exp(-stepMs / 1000.0)
        fastReleaseCoeff = 1 - exp(-stepMs / 3000.0)
    }

    // MARK: - Processing

    /// Process a new raw AGC gain value, returning the smoothed offset.
    ///
    /// Call this at the polling interval (e.g., every 200 ms from AudioEngine).
    ///
    /// - Parameter rawGainDb: The AGC's current gain in dB (always ≤ 0).
    /// - Returns: The smoothed gain offset in dB.
    @discardableResult
    func process(_ rawGainDb: Float) -> Float {
        let delta = rawGainDb - smoothedDb
        let absDelta = abs(delta)

        let coeff: Float
        if delta >= 0 {
            // Gain increasing (becoming less negative — AGC releasing, signal getting quieter)
            coeff = absDelta > fastThresholdDb ? fastAttackCoeff : attackCoeff
        } else {
            // Gain decreasing (becoming more negative — AGC attacking, signal getting louder)
            coeff = absDelta > fastThresholdDb ? fastReleaseCoeff : releaseCoeff
        }

        smoothedDb += coeff * delta
        return smoothedDb
    }

    /// Reset the smoother state (e.g., when AGC is toggled off/on).
    func reset() {
        smoothedDb = 0
    }
}
