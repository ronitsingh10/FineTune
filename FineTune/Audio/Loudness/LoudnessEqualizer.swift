import Foundation

/// Downward-only AGC (Auto Gain Control).
///
/// Unlike standard compressors that boost quiet sounds, this AGC operates strictly
/// on a downward-only (attenuation) principle:
///
/// 1. **Drive** – the input signal is first multiplied by a static gain (Drive).
/// 2. **Target Level** – the AGC attenuates the driven signal so its average
///    perceived volume matches the Target level.
/// 3. **Gain Envelope** – internal gain multiplier G:
///    - If the driven signal is below the Target → G = 1.0 (0 dB, no change).
///    - If the driven signal exceeds the Target → G < 1.0 (negative dB) to
///      compress the volume down.
/// 4. **Proportional Ballistics** – attack/release speeds are proportional to
///    the overshoot/deficit (dB/sec per 6 dB), creating smooth exponential
///    approach curves.
/// 5. **Anti-Breathing** – Silence Gate (freezes gain during pauses) and
///    AGC Window (dead zone around target) prevent unwanted gain pumping.
/// 6. **Sudden Jump Protection** – instantaneous fast-attack override that
///    bypasses the slow attack ramp when a single peak drastically overshoots.
///
/// **RT-safety contract**: All mutable state is owned exclusively by the real-time
/// audio thread after init. Settings and sample-rate changes are handled by creating
/// a **new** instance on the main thread, atomically swapping the pointer in
/// ProcessTapController, and deferring destruction of the old instance by 500 ms.
final class LoudnessEqualizer: @unchecked Sendable {

    // MARK: - Private state (exclusively RT-thread owned after init)

    private let settings: LoudnessEqualizerSettings

    /// Precomputed attack speed normalised to per-sample, per-dB-of-overshoot.
    /// `(attackSpeed / 6.0) / sampleRate`
    private let attackSpeedNorm: Float

    /// Precomputed release speed normalised to per-sample, per-dB-of-deficit.
    /// `(releaseSpeed / 6.0) / sampleRate`
    private let releaseSpeedNorm: Float

    /// Custom parametric EQ sidechain filters (vectorized).
    private var sidechainFilter: ParametricSidechainFilter

    /// Per-sample fallback coefficient (from silenceGateFallbackTimeS).
    private let fallbackAlpha: Float

    private struct AgcBandState {
        var envelopeSq: Float = 0
        var currentGainDb: Float
        var currentGainLinear: Float

        init(initialGainDb: Float) {
            self.currentGainDb = initialGainDb
            self.currentGainLinear = LoudnessEqualizerMath.dbToLinear(initialGainDb)
        }
    }

    /// One-pole envelope follower state (squared magnitude) for broadband silence gate.
    private var envelopeSq: Float = 0

    /// Envelope follower attack coefficient (fast, ~10 ms).
    private let envAttackCoeff: Float

    /// Envelope follower release coefficient (moderate, ~200 ms).
    private let envReleaseCoeff: Float

    /// Sudden jump protection attack coefficient (fast, ~5 ms).
    private let sjpAttackCoeff: Float

    /// Precomputed ln(gateSlowdownFactor) for RT-path: replaces pow(base,x) with exp(ln*x).
    private let lnGateSlowdownFactor: Float

    private var crossoverL: LinkwitzRileyCrossover2
    private var crossoverR: LinkwitzRileyCrossover2
    private var masterBand: AgcBandState
    private var bassBand: AgcBandState

    /// Current gain in dB. Always ≤ 0 (downward-only). Exposes master band gain.
    private(set) var currentGainDb: Float

    /// Cached linear version of currentGainDb for the current processing block.
    private var currentGainLinear: Float

    /// Dry/wet blend for AGC effect intensity. 0.0 = drive only, 1.0 = full AGC.
    /// Main-thread write, RT-thread read via nonisolated(unsafe).
    nonisolated(unsafe) var _intensity: Float = 1.0

    // MARK: - Init

    init(settings: LoudnessEqualizerSettings, sampleRate: Float) {
        self.settings = settings
        self.attackSpeedNorm = (settings.attackSpeedDbPerSecPer6Db / 6.0) / sampleRate
        self.releaseSpeedNorm = (settings.releaseSpeedDbPerSecPer6Db / 6.0) / sampleRate
        self.sidechainFilter = ParametricSidechainFilter(sampleRate: sampleRate)

        let fallbackTime = settings.silenceGateFallbackTimeS
        if fallbackTime > 0 {
            self.fallbackAlpha = Float(1.0 - exp(-1.0 / (Double(sampleRate) * Double(fallbackTime))))
        } else {
            self.fallbackAlpha = 0.0
        }

        // Envelope follower: 10 ms attack, 200 ms release
        let samplePeriodMs: Float = 1000.0 / sampleRate
        self.envAttackCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: 10, stepMs: samplePeriodMs
        )
        self.envReleaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: 200, stepMs: samplePeriodMs
        )
        self.sjpAttackCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: 5.0, stepMs: samplePeriodMs
        )
        self.lnGateSlowdownFactor = log(max(settings.gateSlowdownFactor, 1e-9))

        self.crossoverL = LinkwitzRileyCrossover2(frequency: 150.0, sampleRate: Double(sampleRate))
        self.crossoverR = LinkwitzRileyCrossover2(frequency: 150.0, sampleRate: Double(sampleRate))
        let initialGain = -settings.driveDb
        self.masterBand = AgcBandState(initialGainDb: initialGain)
        self.bassBand = AgcBandState(initialGainDb: initialGain)

        // Start fully attenuated to avoid initial pop on first enabled frame.
        // Release will smoothly bring gain up as the AGC settles.
        self.currentGainDb = initialGain
        self.currentGainLinear = LoudnessEqualizerMath.dbToLinear(initialGain)
        self._intensity = 1.0
    }

    // MARK: - Public API

    /// Whether loudness processing is active.
    var isEnabled: Bool { settings.enabled }

    /// The current settings snapshot (read from main thread for creating replacement instances).
    var currentSettings: LoudnessEqualizerSettings { settings }

    /// Set the dry/wet intensity blend. Main thread only.
    ///
    /// - Parameter intensity: 0.0 (drive only, no normalization) to 1.0 (full AGC).
    func setIntensity(_ intensity: Float) {
        _intensity = max(0.0, min(1.0, intensity))
    }

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

        // Scale drive in dB domain for perceptually linear intensity control.
        // At intensity=0 → 0 dB (unity passthrough), at intensity=1 → full driveDb.
        let effectiveDriveDb = max(0.0, Double(settings.driveDb) * Double(_intensity))
        let effectiveDrive = LoudnessEqualizerMath.dbToLinear(Float(effectiveDriveDb))
        let targetDb = settings.targetLevelDb
        let attackNorm = attackSpeedNorm
        let releaseNorm = releaseSpeedNorm
        let jumpProtection = settings.suddenJumpProtectionEnabled
        let silenceGateThreshold = settings.silenceGateThresholdDb
        let silenceGateSlowdown = settings.silenceGateSlowdownDb

        let suddenDropProtection = settings.suddenDropProtection
        let suddenDropThreshold = settings.suddenDropThresholdDb
        let suddenDropSpeedup = settings.suddenDropSpeedup
        let agcWindowSize = settings.agcWindowSizeDb
        let progressiveRatioEnabled = settings.progressiveRatioEnabled
        let minRatio = settings.minRatio
        let maxRatio = settings.maxRatio
        let progressiveRate = settings.progressiveRate
        let targetIdleGain = min(0.0, settings.silenceGateIdleGainDb)

        var envSq = envelopeSq

        if channelCount == 2 {
            for frame in 0..<frameCount {
                let base = frame * 2
                let inL = input[base]
                let inR = input[base + 1]

                // 1. Apply Drive
                let drivenL = inL * effectiveDrive
                let drivenR = inR * effectiveDrive

                // 2. Split driven signals with Crossover
                let (lowL, highL) = crossoverL.process(drivenL)
                let (lowR, highR) = crossoverR.process(drivenR)

                // 3. Sidechain: downmix driven stereo to mono and filter in parallel via SIMD
                let mono = (drivenL + drivenR) * 0.5
                let bassMono = (lowL + lowR) * 0.5
                let masterMono = (highL + highR) * 0.5

                let (weighted, bassMonoWeighted, masterMonoWeighted) = sidechainFilter.process(
                    mono: mono,
                    bass: bassMono,
                    master: masterMono
                )

                // 4. Update broadband envelope and gating factor
                let sampleSq = weighted * weighted
                if sampleSq > envSq {
                    envSq += envAttackCoeff * (sampleSq - envSq)
                } else {
                    envSq += envReleaseCoeff * (sampleSq - envSq)
                }
                let levelDb = LoudnessEqualizerMath.meanSquareToDb(envSq)
                let gateRange = silenceGateSlowdown - silenceGateThreshold
                let gatingFactor: Float
                if gateRange > 0 {
                    gatingFactor = LoudnessEqualizerMath.clamp((levelDb - silenceGateThreshold) / gateRange, min: 0.0, max: 1.0)
                } else {
                    gatingFactor = levelDb >= silenceGateThreshold ? 1.0 : 0.0
                }

                let bassDrivenPeak = max(abs(lowL), abs(lowR))
                let masterDrivenPeak = max(abs(highL), abs(highR))

                // 5. Process AGC for both bands
                processBandSample(
                    band: &bassBand,
                    weighted: bassMonoWeighted,
                    drivenPeak: bassDrivenPeak,
                    targetDb: targetDb,
                    attackNorm: attackNorm,
                    releaseNorm: releaseNorm,
                    jumpProtection: jumpProtection,
                    broadbandGatingFactor: gatingFactor,
                    silenceGateSlowdown: silenceGateSlowdown,
                    suddenDropProtection: suddenDropProtection,
                    suddenDropThresholdDb: suddenDropThreshold,
                    suddenDropSpeedup: suddenDropSpeedup,
                    agcWindowSize: agcWindowSize,
                    progressiveRatioEnabled: progressiveRatioEnabled,
                    minRatio: minRatio,
                    maxRatio: maxRatio,
                    progressiveRate: progressiveRate,
                    targetIdleGain: targetIdleGain
                )

                processBandSample(
                    band: &masterBand,
                    weighted: masterMonoWeighted,
                    drivenPeak: masterDrivenPeak,
                    targetDb: targetDb,
                    attackNorm: attackNorm,
                    releaseNorm: releaseNorm,
                    jumpProtection: jumpProtection,
                    broadbandGatingFactor: gatingFactor,
                    silenceGateSlowdown: silenceGateSlowdown,
                    suddenDropProtection: suddenDropProtection,
                    suddenDropThresholdDb: suddenDropThreshold,
                    suddenDropSpeedup: suddenDropSpeedup,
                    agcWindowSize: agcWindowSize,
                    progressiveRatioEnabled: progressiveRatioEnabled,
                    minRatio: minRatio,
                    maxRatio: maxRatio,
                    progressiveRate: progressiveRate,
                    targetIdleGain: targetIdleGain
                )

                // 6. Apply Bass-to-Master coupling clamp
                bassBand.currentGainDb = min(bassBand.currentGainDb, masterBand.currentGainDb + 3.0)
                if bassBand.currentGainDb > 0 { bassBand.currentGainDb = 0 }
                bassBand.currentGainLinear = LoudnessEqualizerMath.dbToLinear(bassBand.currentGainDb)

                // 7. Apply gains to bands and sum
                let outL = lowL * bassBand.currentGainLinear + highL * masterBand.currentGainLinear
                let outR = lowR * bassBand.currentGainLinear + highR * masterBand.currentGainLinear

                output[base] = outL
                output[base + 1] = outR
            }
        } else if channelCount == 1 {
            for frame in 0..<frameCount {
                let inVal = input[frame]
                let driven = inVal * effectiveDrive

                // 2. Split driven mono with Crossover
                let (low, high) = crossoverL.process(driven)

                // 3. Sidechain: filter inputs in parallel via SIMD
                let (weighted, bassMonoWeighted, masterMonoWeighted) = sidechainFilter.process(
                    mono: driven,
                    bass: low,
                    master: high
                )

                // 4. Update broadband envelope and gating factor
                let sampleSq = weighted * weighted
                if sampleSq > envSq {
                    envSq += envAttackCoeff * (sampleSq - envSq)
                } else {
                    envSq += envReleaseCoeff * (sampleSq - envSq)
                }
                let levelDb = LoudnessEqualizerMath.meanSquareToDb(envSq)
                let gateRange = silenceGateSlowdown - silenceGateThreshold
                let gatingFactor: Float
                if gateRange > 0 {
                    gatingFactor = LoudnessEqualizerMath.clamp((levelDb - silenceGateThreshold) / gateRange, min: 0.0, max: 1.0)
                } else {
                    gatingFactor = levelDb >= silenceGateThreshold ? 1.0 : 0.0
                }

                let bassDrivenPeak = abs(low)
                let masterDrivenPeak = abs(high)

                // 5. Process AGC for both bands
                processBandSample(
                    band: &bassBand,
                    weighted: bassMonoWeighted,
                    drivenPeak: bassDrivenPeak,
                    targetDb: targetDb,
                    attackNorm: attackNorm,
                    releaseNorm: releaseNorm,
                    jumpProtection: jumpProtection,
                    broadbandGatingFactor: gatingFactor,
                    silenceGateSlowdown: silenceGateSlowdown,
                    suddenDropProtection: suddenDropProtection,
                    suddenDropThresholdDb: suddenDropThreshold,
                    suddenDropSpeedup: suddenDropSpeedup,
                    agcWindowSize: agcWindowSize,
                    progressiveRatioEnabled: progressiveRatioEnabled,
                    minRatio: minRatio,
                    maxRatio: maxRatio,
                    progressiveRate: progressiveRate,
                    targetIdleGain: targetIdleGain
                )

                processBandSample(
                    band: &masterBand,
                    weighted: masterMonoWeighted,
                    drivenPeak: masterDrivenPeak,
                    targetDb: targetDb,
                    attackNorm: attackNorm,
                    releaseNorm: releaseNorm,
                    jumpProtection: jumpProtection,
                    broadbandGatingFactor: gatingFactor,
                    silenceGateSlowdown: silenceGateSlowdown,
                    suddenDropProtection: suddenDropProtection,
                    suddenDropThresholdDb: suddenDropThreshold,
                    suddenDropSpeedup: suddenDropSpeedup,
                    agcWindowSize: agcWindowSize,
                    progressiveRatioEnabled: progressiveRatioEnabled,
                    minRatio: minRatio,
                    maxRatio: maxRatio,
                    progressiveRate: progressiveRate,
                    targetIdleGain: targetIdleGain
                )

                // 6. Apply Bass-to-Master coupling clamp
                bassBand.currentGainDb = min(bassBand.currentGainDb, masterBand.currentGainDb + 3.0)
                if bassBand.currentGainDb > 0 { bassBand.currentGainDb = 0 }
                bassBand.currentGainLinear = LoudnessEqualizerMath.dbToLinear(bassBand.currentGainDb)

                // 7. Apply gains to bands and sum
                output[frame] = low * bassBand.currentGainLinear + high * masterBand.currentGainLinear
            }
        } else {
            let invCh = 1.0 / Float(channelCount)
            for f in 0..<frameCount {
                let base = f * channelCount

                // Downmix driven signal for sidechain + track peak for jump protection
                var drivenMono: Float = 0
                var maxDrivenAbs: Float = 0
                for ch in 0..<channelCount {
                    let driven = input[base + ch] * effectiveDrive
                    drivenMono += driven
                    let a = abs(driven)
                    if a > maxDrivenAbs { maxDrivenAbs = a }
                }
                drivenMono *= invCh

                // Filter sidechains in parallel via SIMD.
                // Bass lane ([1]) is unused in multi-channel — no crossover splitting.
                // The zero input accumulates harmless filter state; lane is discarded via `_`.
                let (weighted, _, masterMonoWeighted) = sidechainFilter.process(
                    mono: drivenMono,
                    bass: 0.0,
                    master: drivenMono
                )

                // Broadband Envelope
                let sampleSq = weighted * weighted
                if sampleSq > envSq {
                    envSq += envAttackCoeff * (sampleSq - envSq)
                } else {
                    envSq += envReleaseCoeff * (sampleSq - envSq)
                }
                let levelDb = LoudnessEqualizerMath.meanSquareToDb(envSq)
                let gateRange = silenceGateSlowdown - silenceGateThreshold
                let gatingFactor: Float
                if gateRange > 0 {
                    gatingFactor = LoudnessEqualizerMath.clamp((levelDb - silenceGateThreshold) / gateRange, min: 0.0, max: 1.0)
                } else {
                    gatingFactor = levelDb >= silenceGateThreshold ? 1.0 : 0.0
                }

                processBandSample(
                    band: &masterBand,
                    weighted: masterMonoWeighted,
                    drivenPeak: maxDrivenAbs,
                    targetDb: targetDb,
                    attackNorm: attackNorm,
                    releaseNorm: releaseNorm,
                    jumpProtection: jumpProtection,
                    broadbandGatingFactor: gatingFactor,
                    silenceGateSlowdown: silenceGateSlowdown,
                    suddenDropProtection: suddenDropProtection,
                    suddenDropThresholdDb: suddenDropThreshold,
                    suddenDropSpeedup: suddenDropSpeedup,
                    agcWindowSize: agcWindowSize,
                    progressiveRatioEnabled: progressiveRatioEnabled,
                    minRatio: minRatio,
                    maxRatio: maxRatio,
                    progressiveRate: progressiveRate,
                    targetIdleGain: targetIdleGain
                )

                // Apply masterBand gain to all channels
                for ch in 0..<channelCount {
                    output[base + ch] = input[base + ch] * effectiveDrive * masterBand.currentGainLinear
                }
            }
        }

        // Persist state for next call
        currentGainDb = masterBand.currentGainDb
        currentGainLinear = masterBand.currentGainLinear
        envelopeSq = envSq
    }

    // MARK: - AGC Core (per-sample)

    @inline(__always)
    private func processBandSample(
        band: inout AgcBandState,
        weighted: Float,
        drivenPeak: Float,
        targetDb: Float,
        attackNorm: Float,
        releaseNorm: Float,
        jumpProtection: Bool,
        broadbandGatingFactor: Float,
        silenceGateSlowdown: Float,

        suddenDropProtection: Bool,
        suddenDropThresholdDb: Float,
        suddenDropSpeedup: Float,
        agcWindowSize: Float,
        progressiveRatioEnabled: Bool,
        minRatio: Float,
        maxRatio: Float,
        progressiveRate: Float,
        targetIdleGain: Float
    ) {
        // 1. Envelope detection (asymmetric one-pole on squared magnitude)
        let sampleSq = weighted * weighted
        if sampleSq > band.envelopeSq {
            band.envelopeSq += envAttackCoeff * (sampleSq - band.envelopeSq)
        } else {
            band.envelopeSq += envReleaseCoeff * (sampleSq - band.envelopeSq)
        }
        let levelDb = LoudnessEqualizerMath.meanSquareToDb(band.envelopeSq)

        // 2. Silence Gate & AGC Ballistics
        let deltaInput = levelDb - targetDb
        let deltaOutput = deltaInput + band.currentGainDb
        let halfWindow = agcWindowSize * 0.5
        let gatingFactor = broadbandGatingFactor

        var gainDb = band.currentGainDb

        // Compute target gain based on input overshoot/level relative to target level
        var targetGainDb = -deltaInput
        let inputOvershootDb = deltaInput - halfWindow
        if progressiveRatioEnabled && minRatio > 1.0 {
            let sMin = 1.0 / minRatio
            let sMax = maxRatio > 0.0 ? (1.0 / maxRatio) : 0.0
            let s = sMax + (sMin - sMax) * exp(-progressiveRate * max(inputOvershootDb, 0.0))
            targetGainDb = -halfWindow - inputOvershootDb * (1.0 - s)
        }

        if deltaOutput > halfWindow {
            // Output is too loud — ATTACK towards targetGainDb (never gated, to prevent clipping)
            let overshootDb = deltaInput - halfWindow
            let attackDelta = attackNorm * max(overshootDb, 0)
            gainDb -= attackDelta
            if gainDb < targetGainDb { gainDb = targetGainDb }
        } else if deltaOutput < -halfWindow {
            // Output is too quiet — RELEASE/RECOVERY towards active target (either 0 dB or targetGainDb)
            let activeTargetGainDb = min(0.0, targetGainDb)
            var speedMult: Float = 1.0

            if levelDb < silenceGateSlowdown {
                speedMult *= exp(lnGateSlowdownFactor * (1.0 - gatingFactor))
            }
            if suddenDropProtection && deltaInput < -suddenDropThresholdDb {
                speedMult *= suddenDropSpeedup
            }

            let activeAlpha = releaseNorm * speedMult

            // Interpolate target and speed between active release and idle gain fallback
            let effectiveTargetGainDb = gatingFactor * activeTargetGainDb + (1.0 - gatingFactor) * targetIdleGain
            let effectiveAlpha = gatingFactor * activeAlpha + (1.0 - gatingFactor) * (1.0 - gatingFactor) * fallbackAlpha

            let releaseDeficitDb = effectiveTargetGainDb - gainDb
            gainDb += releaseDeficitDb * effectiveAlpha
            if gainDb > activeTargetGainDb { gainDb = activeTargetGainDb }
            if gainDb > 0 { gainDb = 0 }
        } else {
            // Output is within comfort zone (window)
            // If gatingFactor < 1.0, we drift towards idle gain, but with a speed scaled quadratically by (1 - gatingFactor)^2
            if fallbackAlpha > 0 {
                let effectiveAlpha = (1.0 - gatingFactor) * (1.0 - gatingFactor) * fallbackAlpha
                let deficitDb = targetIdleGain - gainDb
                gainDb += deficitDb * effectiveAlpha
                if gainDb > 0 { gainDb = 0 }
            }
        }

        // 3. Sudden Jump Protection (always overrides silence gate and window)
        if jumpProtection && drivenPeak > 0 {
            let drivenPeakDb = LoudnessEqualizerMath.linearToDb(drivenPeak)
            let outputDb = drivenPeakDb + gainDb
            let jumpThresholdDb = targetDb + 4.0
            if outputDb > jumpThresholdDb {
                let targetSjpGainDb = jumpThresholdDb - drivenPeakDb
                // Smoothly attack toward the jump protection target gain.
                // We use a fast attack time constant (5.0 ms) to pull the gain down
                // without introducing a step discontinuity (which causes clicks/pops).
                gainDb += sjpAttackCoeff * (targetSjpGainDb - gainDb)
            }
        }

        band.currentGainDb = gainDb
        band.currentGainLinear = LoudnessEqualizerMath.dbToLinear(gainDb)
    }

    #if DEBUG
    /// Internal properties exposed for unit testing band-coupling behavior
    var bassGainDb: Float { bassBand.currentGainDb }
    var masterGainDb: Float { masterBand.currentGainDb }
    #endif
}
