struct LoudnessEqualizerSettings: Codable, Equatable, Sendable {
    var targetLoudnessDb: Float = -12
    var maxBoostDb: Float = 15
    var maxCutDb: Float = 4
    var compressionThresholdOffsetDb: Float = 6
    var compressionRatio: Float = 1.6
    var compressionKneeDb: Float = 8

    var analysisWindowMs: Float = 30
    var analysisHopMs: Float = 15

    var detectorAttackMs: Float = 25
    var detectorReleaseMs: Float = 400

    var gainAttackMs: Float = 180
    var gainReleaseMs: Float = 5000

    var noiseFloorThresholdDb: Float = -48
    var lowLevelMaxBoostDb: Float = 1.5

    var enabled: Bool = false
}
