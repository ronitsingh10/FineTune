import Foundation

/// Loudness equalizer that applies K-weighted loudness measurement and
/// asymmetric gain smoothing to keep perceived loudness near a target level.
///
/// Input/output memory layout: interleaved — frame-major ordering.
///   `output[f * channelCount + ch]`
///
/// **RT-safety contract**: All mutable state is owned exclusively by the real-time
/// audio thread after init. Settings and sample-rate changes are handled by creating
/// a **new** instance on the main thread, atomically swapping the `nonisolated(unsafe)`
/// pointer in ProcessTapController, and deferring destruction of the old instance by
/// 500ms (matching the BiquadProcessor.swapSetup pattern).
///
/// This eliminates the data-race window that existed when `updateSettings()` and
/// `updateSampleRate()` mutated sub-processor state from the main thread while
/// `process()` read/wrote from the RT thread.
final class LoudnessEqualizer: @unchecked Sendable {

    // MARK: - Private state (exclusively RT-thread owned after init)

    private let settings: LoudnessEqualizerSettings
    private let kFilter: KWeightingFilter
    private let detector: LoudnessDetector
    private let gainComputer: GainComputer
    private let gainSmoother: GainSmoother
    private var currentLinearGain: Float

    // MARK: - Init

    init(settings: LoudnessEqualizerSettings, sampleRate: Float) {
        self.settings = settings
        self.kFilter = KWeightingFilter(sampleRate: sampleRate)
        self.detector = LoudnessDetector(settings: settings, sampleRate: sampleRate)
        self.gainComputer = GainComputer(settings: settings)
        self.gainSmoother = GainSmoother(settings: settings, sampleRate: sampleRate)
        self.currentLinearGain = LoudnessEqualizerMath.dbToLinear(self.gainSmoother.currentGainDb)
    }

    // MARK: - Public API

    /// Whether loudness processing is active.
    var isEnabled: Bool { settings.enabled }

    /// The current settings snapshot (read from main thread for creating replacement instances).
    var currentSettings: LoudnessEqualizerSettings { settings }

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
        let enabled = settings.enabled
        if !enabled {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
            }
            return
        }

        var linearGain = currentLinearGain

        if channelCount == 2 {
            for frame in 0..<frameCount {
                let base = frame * 2
                let mono = (input[base] + input[base + 1]) * 0.5
                let weighted = kFilter.processSample(mono)

                if let newLevel = detector.ingest(weightedSample: weighted) {
                    let desiredGain = gainComputer.desiredGainDb(forLevelDb: newLevel)
                    let smoothedGain = gainSmoother.process(targetGainDb: desiredGain)
                    linearGain = LoudnessEqualizerMath.dbToLinear(smoothedGain)
                    currentLinearGain = linearGain
                }

                output[base] = input[base] * linearGain
                output[base + 1] = input[base + 1] * linearGain
            }
            return
        }

        let inverseChannelCount = 1.0 / Float(channelCount)
        for f in 0..<frameCount {
            let base = f * channelCount

            // --- Sidechain: downmix to mono (interleaved layout) ---
            var mono: Float = 0
            for ch in 0..<channelCount {
                mono += input[base + ch]
            }
            mono *= inverseChannelCount

            // --- K-weighting ---
            let weighted = kFilter.processSample(mono)

            // --- Detector ---
            if let newLevel = detector.ingest(weightedSample: weighted) {
                let desiredGain = gainComputer.desiredGainDb(forLevelDb: newLevel)
                let smoothedGain = gainSmoother.process(targetGainDb: desiredGain)
                linearGain = LoudnessEqualizerMath.dbToLinear(smoothedGain)
                currentLinearGain = linearGain
            }

            // --- Apply gain to all channels ---
            for ch in 0..<channelCount {
                output[base + ch] = input[base + ch] * linearGain
            }
        }
    }
}
