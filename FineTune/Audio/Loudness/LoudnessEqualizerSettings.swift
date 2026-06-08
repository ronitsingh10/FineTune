nonisolated struct LoudnessEqualizerSettings: Codable, Equatable, Sendable {
    /// Static input gain before AGC analysis.
    var driveDb: Float = 24.0
    /// Target output level for average loudness.
    var targetLevelDb: Float = -7.9
    /// Attack speed in dB/sec per 6 dB of signal overshoot above target.
    var attackSpeedDbPerSecPer6Db: Float = 6.0
    /// Release speed in dB/sec per 6 dB of gain deficit below 0 dB.
    var releaseSpeedDbPerSecPer6Db: Float = 2.45
    /// Instant fast-attack override for massive overshoots.
    var suddenJumpProtectionEnabled: Bool = true
    /// Silence gate threshold (dB). When the driven signal level falls below this,
    /// the active release is frozen and gain slowly drifts to the idle gain target.
    var silenceGateThresholdDb: Float = -16.0
    /// Gate slowdown threshold (dB). Between freeze and this level, active release is slowed.
    var silenceGateSlowdownDb: Float = -12.0
    /// Gate slowdown multiplier.
    /// 0.086 corresponds to an ~11x slower release, tuned by ear for conversational speech dynamics.
    var gateSlowdownFactor: Float = 0.086
    /// Silence gate fallback recovery time in seconds.
    /// 9.0s provides a very slow, unnoticeable drift back to idle gain when audio pauses.
    var silenceGateFallbackTimeS: Float = 9.0
    /// Whether Sudden Drop Protection is enabled.
    var suddenDropProtection: Bool = true
    /// Threshold in dB below target to activate speedup.
    var suddenDropThresholdDb: Float = 10.0
    /// Speedup factor for release under sudden drop.
    var suddenDropSpeedup: Float = 2.5
    /// AGC window / dead zone (dB). A comfort zone around the target level where
    /// the AGC holds its current gain. If |level - target| <= window/2, no adjustment.
    var agcWindowSizeDb: Float = 4.5
    /// Whether Orban-style progressive compression ratio is enabled.
    var progressiveRatioEnabled: Bool = true
    /// Starting compression ratio near the window threshold.
    var minRatio: Float = 2.0
    /// Maximum compression ratio for large overshoots.
    var maxRatio: Float = Float.infinity
    /// Speed of transition from minRatio to maxRatio per dB of overshoot.
    var progressiveRate: Float = 0.15
    /// Silence gate fallback target level in dB (Orban Idle Gain).
    var silenceGateIdleGainDb: Float = -24.0

    /// Whether AGC processing is active.
    var enabled: Bool = false
}
