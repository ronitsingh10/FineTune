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
/// 6. **Sidechain Filtering** – 200 Hz Butterworth High-Pass Filter to prevent
///    low-frequency bass notes/kicks from triggering compression and causing pumping.
///
/// **RT-safety contract**: All mutable state is owned exclusively by the real-time
/// audio thread after init. Settings and sample-rate changes are handled by creating
/// a **new** instance on the main thread, atomically swapping the pointer in
/// ProcessTapController, and deferring destruction of the old instance by 500 ms.
final class PostAgcCompressor: @unchecked Sendable {

    // MARK: - Private state (exclusively RT-thread owned after init)

    private let settings: PostAgcCompressorSettings
    private let sampleRate: Float

    private final class CompressorBand: @unchecked Sendable {
        let thresholdOffsetDb: Float
        let ratio: Float
        let attackMs: Float
        let releaseMs: Float
        let maxReleaseSpeed: Float
        let exponentialRelease: Float
        
        // Mutable state (RT thread only)
        var gainReductionDb: Float = 0
        
        // Coefficients
        private var slope: Float = 0
        private var kneeHalfDb: Float = 0
        private var attackCoeff: Float = 0
        private var releaseCoeff: Float = 0
        private var maxReleaseCoeff: Float = 0
        
        init(thresholdOffsetDb: Float, ratio: Float, attackMs: Float, releaseMs: Float, maxReleaseSpeed: Float, exponentialRelease: Float, sampleRate: Float) {
            self.thresholdOffsetDb = thresholdOffsetDb
            self.ratio = ratio
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.maxReleaseSpeed = maxReleaseSpeed
            self.exponentialRelease = exponentialRelease
            updateSampleRate(sampleRate)
        }
        
        func updateSampleRate(_ sampleRate: Float) {
            self.slope = 1.0 - 1.0 / max(ratio, 1.0)
            self.kneeHalfDb = 0.1 * 0.5 // Default knee is 0.1 dB
            let samplePeriodMs: Float = 1000.0 / sampleRate
            let attackTau = attackMs / 1.966
            self.attackCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: attackTau, stepMs: samplePeriodMs)
            self.releaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: releaseMs, stepMs: samplePeriodMs)
            let maxReleaseSpeed = max(self.maxReleaseSpeed, 0.001)
            self.maxReleaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: releaseMs / maxReleaseSpeed, stepMs: samplePeriodMs)
        }
        
        func calculateGainReduction(levelDb: Float, globalThresholdDb: Float) -> Float {
            let bandThresholdDb = globalThresholdDb + thresholdOffsetDb
            let desiredGrDb: Float
            let kneeDb: Float = 0.1
            if levelDb > bandThresholdDb - kneeHalfDb && levelDb < bandThresholdDb + kneeHalfDb {
                let x = levelDb - bandThresholdDb + kneeHalfDb
                let kneeFactor = (x * x) / (2.0 * max(kneeDb, 1e-6))
                desiredGrDb = -slope * kneeFactor
            } else if levelDb >= bandThresholdDb + kneeHalfDb {
                let overshootDb = levelDb - bandThresholdDb
                desiredGrDb = -slope * overshootDb
            } else {
                desiredGrDb = 0
            }
            
            if desiredGrDb < gainReductionDb {
                gainReductionDb += attackCoeff * (desiredGrDb - gainReductionDb)
            } else {
                var adjustedRelease = releaseCoeff
                let expRelease = exponentialRelease
                let maxReleaseDb: Float = 12.0
                let normalized = min(abs(gainReductionDb) / maxReleaseDb, 1.0)
                let expFactor = 1.0 - expRelease * (1.0 - normalized * normalized)
                adjustedRelease = releaseCoeff * max(expFactor, 0.01)
                adjustedRelease = min(adjustedRelease, maxReleaseCoeff)
                gainReductionDb += adjustedRelease * (desiredGrDb - gainReductionDb)
            }
            
            if gainReductionDb > 0 { gainReductionDb = 0 }
            return LoudnessEqualizerMath.dbToLinear(gainReductionDb)
        }
    }

    private let band1: CompressorBand
    private let band2: CompressorBand
    private let band3: CompressorBand

    private var crossover200Hz: [LinkwitzRileyCrossover2] = []
    private var crossover77Hz: [LinkwitzRileyCrossover2] = []

    // MARK: - Init

    init(settings: PostAgcCompressorSettings, sampleRate: Float) {
        self.settings = settings
        self.sampleRate = sampleRate

        self.band1 = CompressorBand(
            thresholdOffsetDb: -8.9,
            ratio: 4.0,
            attackMs: 67.0,
            releaseMs: 1080.0,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )
        self.band2 = CompressorBand(
            thresholdOffsetDb: -6.0,
            ratio: 4.0,
            attackMs: 52.0,
            releaseMs: 599.0,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )
        self.band3 = CompressorBand(
            thresholdOffsetDb: 0.0,
            ratio: settings.ratio,
            attackMs: settings.attackMs,
            releaseMs: settings.releaseMs,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )

        // Pre-allocate arrays for 2 channels (stereo) to prevent heap allocation on the audio thread
        self.crossover200Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 200.0, sampleRate: Double(sampleRate)) }
        self.crossover77Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 77.0, sampleRate: Double(sampleRate)) }
        self.band1Samples = [Float](repeating: 0, count: 2)
        self.band2Samples = [Float](repeating: 0, count: 2)
        self.band3Samples = [Float](repeating: 0, count: 2)
    }

    // MARK: - Public API

    /// Whether compression is active.
    var isEnabled: Bool { settings.enabled }

    /// The current settings snapshot (read from main thread for creating replacement instances).
    var currentSettings: PostAgcCompressorSettings { settings }

    private var band1Samples: [Float] = []
    private var band2Samples: [Float] = []
    private var band3Samples: [Float] = []

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

        // Dynamically match filter and buffer counts to channel count if it doesn't match,
        // though in practice it is stereo. Since this only mutates properties on change,
        // it is RT-safe once settled.
        if crossover200Hz.count != channelCount {
            crossover200Hz = (0..<channelCount).map { _ in LinkwitzRileyCrossover2(frequency: 200.0, sampleRate: Double(sampleRate)) }
            crossover77Hz = (0..<channelCount).map { _ in LinkwitzRileyCrossover2(frequency: 77.0, sampleRate: Double(sampleRate)) }
            band1Samples = [Float](repeating: 0, count: channelCount)
            band2Samples = [Float](repeating: 0, count: channelCount)
            band3Samples = [Float](repeating: 0, count: channelCount)
        }

        let globalThresholdDb = settings.thresholdDb

        for frame in 0..<frameCount {
            let base = frame * channelCount

            var peakBand1: Float = 0
            var peakBand2: Float = 0
            var peakBand3: Float = 0

            for ch in 0..<channelCount {
                var sample = input[base + ch]
                if sample.isNaN {
                    sample = 0.0
                }
                let (low200, high200) = crossover200Hz[ch].process(sample)
                let (low77, high77) = crossover77Hz[ch].process(low200)

                band1Samples[ch] = low77
                band2Samples[ch] = high77
                band3Samples[ch] = high200

                let abs1 = abs(low77)
                let abs2 = abs(high77)
                let abs3 = abs(high200)

                if abs1 > peakBand1 { peakBand1 = abs1 }
                if abs2 > peakBand2 { peakBand2 = abs2 }
                if abs3 > peakBand3 { peakBand3 = abs3 }
            }

            let level1Db = LoudnessEqualizerMath.linearToDb(peakBand1)
            let level2Db = LoudnessEqualizerMath.linearToDb(peakBand2)
            let level3Db = LoudnessEqualizerMath.linearToDb(peakBand3)

            let gain1 = band1.calculateGainReduction(levelDb: level1Db, globalThresholdDb: globalThresholdDb)
            let gain2 = band2.calculateGainReduction(levelDb: level2Db, globalThresholdDb: globalThresholdDb)
            let gain3 = band3.calculateGainReduction(levelDb: level3Db, globalThresholdDb: globalThresholdDb)

            for ch in 0..<channelCount {
                output[base + ch] = band1Samples[ch] * gain1 + band2Samples[ch] * gain2 + band3Samples[ch] * gain3
            }
        }
    }
}

