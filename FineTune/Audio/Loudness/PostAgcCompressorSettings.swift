struct PostAgcCompressorSettings: Codable, Equatable, Sendable {
    /// Threshold in dBFS. Signals above this are compressed.
    /// Default 0.0 dBFS — catches overshoots above the AGC target of -7.9 dBFS.
    var thresholdDb: Float = 0.0
    
    /// Compression ratio. Default: 7.6 (from Stereo Tool preset).
    var ratio: Float = 7.6
    
    /// Attack time in milliseconds (time to drop 86% toward target gain).
    /// Default: 2.9 ms.
    var attackMs: Float = 2.9
    
    /// Release time in milliseconds (time to rise 10 dB).
    /// Default: 11.6 ms.
    var releaseMs: Float = 11.6
    
    /// Knee width in dB. 0 = hard knee. Default: 0.1 (very small).
    var kneeDb: Float = 0.1
    
    /// Exponential release factor (0 = linear, closer to 1 = more exponential).
    /// Higher values slow down release as gain reduction approaches 0 dB.
    /// Default: 0.8.
    var exponentialRelease: Float = 0.8
    
    /// Max Release Speed cap (default: 0.502502918).
    /// Divides the release time to compute a maximum release coefficient,
    /// preventing overly fast recovery at deep gain reduction.
    var maxReleaseSpeed: Float = 0.502502918
    
    /// Whether the compressor is active. Auto-enabled when AGC is enabled.
    var enabled: Bool = true
}
