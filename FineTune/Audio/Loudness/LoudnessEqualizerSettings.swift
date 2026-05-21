struct LoudnessEqualizerSettings: Codable, Equatable, Sendable {
    var targetLoudnessDb: Float = -12
    var maxBoostDb: Float = 6
    var maxCutDb: Float = 4
    var compressionThresholdOffsetDb: Float = 6
    var compressionRatio: Float = 1.6
    var compressionKneeDb: Float = 8

    var analysisWindowMs: Float = 100
    var analysisHopMs: Float = 15

    var detectorAttackMs: Float = 25
    var detectorReleaseMs: Float = 600

    var gainAttackMs: Float = 250
    var gainReleaseMs: Float = 3000

    var noiseFloorThresholdDb: Float = -40
    var lowLevelMaxBoostDb: Float = 0.5

    var enabled: Bool = false
}
