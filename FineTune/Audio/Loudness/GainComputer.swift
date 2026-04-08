import Foundation

/// Computes the desired gain in dB given a smoothed loudness level.
/// Pure, stateless value type — RT-safe.
struct GainComputer: Sendable {
    let settings: LoudnessEqualizerSettings

    /// Returns the desired gain (dB) for a wideband leveler that boosts quiet material
    /// and applies a gentle soft-knee cut to louder passages.
    func desiredGainDb(forLevelDb smoothedLevelDb: Float) -> Float {
        let boost = desiredBoostDb(forLevelDb: smoothedLevelDb)
        let cut = desiredCutDb(forLevelDb: smoothedLevelDb)
        return boost + cut
    }

    private func desiredBoostDb(forLevelDb smoothedLevelDb: Float) -> Float {
        let raw = settings.targetLoudnessDb - smoothedLevelDb
        var clamped = LoudnessEqualizerMath.clamp(raw, min: 0, max: settings.maxBoostDb)

        // Step 3: noise-floor protection — cap upward gain when signal is very quiet
        if smoothedLevelDb < settings.noiseFloorThresholdDb, clamped > 0 {
            clamped = min(clamped, settings.lowLevelMaxBoostDb)
        }

        return clamped
    }

    private func desiredCutDb(forLevelDb smoothedLevelDb: Float) -> Float {
        guard settings.maxCutDb > 0 else { return 0 }

        let threshold = settings.targetLoudnessDb + settings.compressionThresholdOffsetDb
        let ratio = max(settings.compressionRatio, 1)
        let kneeWidth = max(settings.compressionKneeDb, 0)

        let compressedLevel = softKneeCompressedLevel(
            inputLevelDb: smoothedLevelDb,
            thresholdDb: threshold,
            ratio: ratio,
            kneeWidthDb: kneeWidth
        )
        let gainReduction = compressedLevel - smoothedLevelDb
        return LoudnessEqualizerMath.clamp(gainReduction, min: -settings.maxCutDb, max: 0)
    }

    private func softKneeCompressedLevel(
        inputLevelDb: Float,
        thresholdDb: Float,
        ratio: Float,
        kneeWidthDb: Float
    ) -> Float {
        guard ratio > 1 else { return inputLevelDb }

        if kneeWidthDb <= 0 {
            guard inputLevelDb > thresholdDb else { return inputLevelDb }
            return thresholdDb + (inputLevelDb - thresholdDb) / ratio
        }

        let kneeHalfWidth = kneeWidthDb * 0.5
        let kneeStart = thresholdDb - kneeHalfWidth
        let kneeEnd = thresholdDb + kneeHalfWidth

        if inputLevelDb <= kneeStart {
            return inputLevelDb
        }

        if inputLevelDb >= kneeEnd {
            return thresholdDb + (inputLevelDb - thresholdDb) / ratio
        }

        let normalizedDistance = inputLevelDb - kneeStart
        let quadraticGain = (1 / ratio - 1) * normalizedDistance * normalizedDistance / (2 * kneeWidthDb)
        return inputLevelDb + quadraticGain
    }
}
