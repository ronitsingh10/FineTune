// FineTune/Audio/Loudness/PostAgcCompressor.swift

import Foundation

/// Post-AGC dynamics compressor that catches transient overshoots the slow AGC
/// may miss (e.g., sudden loud peaks above the AGC target level).
///
/// Operates strictly downward-only (attenuation) after the AGC stage:
/// 1. **Threshold** – signals above `thresholdDb` are compressed.
/// 2. **Ratio** – compression slope (7.6:1 default).
/// 3. **Knee** – soft-knee transition around threshold (0.1 dB default).
/// 4. **Attack/Release** – fast envelope follower to catch transients.
/// 5. **Exponential Release** – release slows as gain reduction approaches 0 dB,
///    preventing audible pumping.
///
/// **RT-safety contract**: All mutable state is owned exclusively by the real-time
/// audio thread after init. Settings and sample-rate changes are handled by creating
/// a **new** instance on the main thread, atomically swapping the pointer in
/// ProcessTapController, and deferring destruction of the old instance by 500 ms.
final class PostAgcCompressor: @unchecked Sendable {

    // MARK: - Private state (exclusively RT-thread owned after init)

    private let settings: PostAgcCompressorSettings

    /// Linear threshold (10^(thresholdDb / 20)).
    private let thresholdLinear: Float

    /// Compression slope: 1 - 1/ratio.
    private let slope: Float

    /// Attack coefficient per sample (one-pole).
    private let attackCoeff: Float

    /// Release coefficient per sample (one-pole).
    private let releaseCoeff: Float

    /// Half the knee width in dB.
    private let kneeHalfDb: Float

    /// Maximum release coefficient (capped by Max Release Speed).
    /// Prevents the release coefficient from exceeding this cap,
    /// which avoids excessively fast recovery at deep gain reduction.
    private let maxReleaseCoeff: Float

    /// Release gate stop threshold in dB. When |GR| < gateStopDb
    /// and desired GR is 0, release is held (frozen).
    private let gateStopDb: Float

    /// Current gain reduction in dB (≤ 0). Initialized to 0 (no reduction).
    private var gainReductionDb: Float = 0

    // MARK: - Init

    init(settings: PostAgcCompressorSettings, sampleRate: Float) {
        self.settings = settings
        self.thresholdLinear = LoudnessEqualizerMath.dbToLinear(settings.thresholdDb)
        self.slope = 1.0 - 1.0 / max(settings.ratio, 1.0)
        self.kneeHalfDb = settings.kneeDb * 0.5

        let samplePeriodMs: Float = 1000.0 / sampleRate

        // Attack (time to drop 86%) → one-pole time constant τ.
        // For a one-pole system: 1 - exp(-attackMs / τ) = 0.86
        // → τ = attackMs / ln(1 / 0.14) = attackMs / 1.966
        let attackTau = settings.attackMs / 1.966
        self.attackCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: attackTau, stepMs: samplePeriodMs
        )

        // Release (time to rise 10 dB) is already equivalent to
        // the one-pole time constant (the time needed to rise 10 dB from the
        // initial rate), so it is used directly as τ.
        self.releaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: settings.releaseMs, stepMs: samplePeriodMs
        )

        // Max Release Speed cap (default: 0.502502918).
        // Caps the release coefficient to prevent fast recovery at deep GR.
        // releaseMs / maxReleaseSpeed yields a shorter effective time constant,
        // which we then convert to a coefficient cap.
        let maxReleaseSpeed = max(settings.maxReleaseSpeed, 0.001) // avoid division by zero
        self.maxReleaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: settings.releaseMs / maxReleaseSpeed, stepMs: samplePeriodMs
        )

        // Release Gate Stop: when |GR| falls below this threshold, freeze release.
        // Prevents flutter near 0 dB GR. From preset: Release Gate Stop=0.978250563 → ~0.191 dB.
        self.gateStopDb = settings.releaseGateStopDb
    }

    // MARK: - Public API

    /// Whether compression is active.
    var isEnabled: Bool { settings.enabled }

    /// The current settings snapshot (read from main thread for creating replacement instances).
    var currentSettings: PostAgcCompressorSettings { settings }

    /// Process audio from an interleaved input buffer to an interleaved output buffer.
    ///
    /// - Parameters:
    ///   - input:        Interleaved input: `input[f * channelCount + ch]`
    ///   - output:       Interleaved output: `output[f * channelCount + ch]`
    ///   - frameCount:   Number of frames per channel.
    ///   - channelCount: Number of channels.
    ///
    /// RT-safe: allocation-free, no logging.
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard settings.enabled else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
            }
            return
        }

        let thresholdDb = settings.thresholdDb
        let slopeVal = slope
        let attack = attackCoeff
        let release = releaseCoeff
        let kneeDb = settings.kneeDb
        let kneeHalf = kneeHalfDb
        let expRelease = settings.exponentialRelease

        var grDb = gainReductionDb

        for frame in 0..<frameCount {
            let base = frame * channelCount

            // 1. Peak detection across channels for this frame
            var peak: Float = 0
            for ch in 0..<channelCount {
                let absVal = abs(input[base + ch])
                if absVal > peak { peak = absVal }
            }

            let levelDb = LoudnessEqualizerMath.linearToDb(peak)

            // 2. Desired gain reduction with optional soft knee
            let desiredGrDb: Float
            if levelDb > thresholdDb - kneeHalf && levelDb < thresholdDb + kneeHalf && kneeDb > 0 {
                // Soft knee region
                let x = levelDb - thresholdDb + kneeHalf
                let kneeFactor = (x * x) / (2.0 * max(kneeDb, 1e-6))
                desiredGrDb = -slopeVal * kneeFactor
            } else if levelDb >= thresholdDb + kneeHalf {
                // Above threshold: compress
                let overshootDb = levelDb - thresholdDb
                desiredGrDb = -slopeVal * overshootDb
            } else {
                // Below threshold: no compression
                desiredGrDb = 0
            }

            // 3. Envelope follower (attack/release)
            if desiredGrDb < grDb {
                // Attack: gain reduction increases (becomes more negative)
                grDb += attack * (desiredGrDb - grDb)
            } else {
                // Release: gain reduction decreases (moves toward 0)

                // Release Gate Stop: if |GR| is below gate threshold and target is 0, hold.
                // Prevents flutter near 0 dB GR.
                if abs(grDb) < gateStopDb && desiredGrDb >= 0 {
                    // Hold — don't release further
                } else {
                    var adjustedRelease = release
                    if expRelease > 0 {
                        // Exponential release: slower as we approach 0 dB gain reduction
                        let maxReleaseDb: Float = 12.0
                        let normalized = min(abs(grDb) / maxReleaseDb, 1.0)
                        let expFactor = 1.0 - expRelease * (1.0 - normalized * normalized)
                        adjustedRelease = release * max(expFactor, 0.01)
                    }
                    // Cap release speed by Max Release Speed
                    adjustedRelease = min(adjustedRelease, maxReleaseCoeff)
                    grDb += adjustedRelease * (desiredGrDb - grDb)
                }
            }

            // Clamp to ≤ 0 (downward-only)
            if grDb > 0 { grDb = 0 }

            // 4. Apply gain reduction
            let gainLin = LoudnessEqualizerMath.dbToLinear(grDb)
            for ch in 0..<channelCount {
                output[base + ch] = input[base + ch] * gainLin
            }
        }

        // Persist state for next call
        gainReductionDb = grDb
    }
}
