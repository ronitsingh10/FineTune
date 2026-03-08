// FineTune/Audio/FXProcessor.swift
//
// Five DSP effects ported from FXSound's open-source codebase (AGPL-3.0).
// Each effect maps user value 0–10 to the exact parameter ranges from FXSound.
//
// ─────────────────────────────────────────────────────────────────────
//  1. CLARITY  → Aural Exciter (dfxp_CommunicateFidelity)
//     Drive:  0 → DSP_AURAL_DRIVE_MAX_VALUE * PLY_FIDELITY_INTENSITY_MAX_SCALE
//             = (TWO_PI/4 * 1.8 * 2 * 0.75) * 0.8 ≈ 3.393
//     Fixed odd/even at DSP_PLAY_AURAL_TUNE_MIDI = 53:
//       odd  = 0 + (53/127)*1.5 ≈ 0.626  (DSP_AURAL_ODD_MIN..MAX = 0..1.5)
//       even = 0.75 - (53/127)*0.75 ≈ 0.437 (DSP_AURAL_EVEN_MIN..MAX = 0.75..0)
//     2nd-order Butterworth HPF on exciter output:
//       fc range = DFXP_AURAL_CONTROL_HERTZ_MIN_VAL(500)..MAX_VAL(10000)
//       at MIDI 53 ≈ 4460 Hz
//
//  2. AMBIENCE → Reverb (dfxp_CommunicateAmbience)
//     Schroeder reverb approximating FXSound's Lexicon-style reverb.
//     Fixed wet=0.273, dry=0.897 (from FXSound fixed wet/dry when active).
//     Music Mode 2 warping: pc_liveliness * 0.34, giving short decay times.
//     Comb feedback g maps user 1→10 to RT60 ≈ 0.3→1.5 s.
//
//  3. SURROUND → Stereo Widener (dfxp_CommunicateSpaciousness)
//     intensity: 0 → DSP_WID_INTENSITY_MAX_VALUE * PLY_WIDENER_BOOST_MAX_SCALE
//              = 1.0 * 0.7 = 0.7
//     M/S width: scales side component by (1 + intensity).
//
//  4. DYNAMIC BOOST → Upward Compressor + Lookahead Limiter
//     (dfxp_CommunicateDynamicBoost, MAXIMIZE_TARGET_LEVEL_SETTING = 0.32)
//     Gain boost 0..21 dB (after PLY_OPTIMIZER_BOOST_MAX_SCALE * MUSIC_MODE2 factor).
//     Peak-following envelope, hard-limit to 0 dBFS.
//
//  5. BASS BOOST → Peaking EQ (dfxp_CommunicateBassBoost / qntIToBoostCutCalc)
//     DSP_PLY_BASSBOOST_CENTER_FREQ = 90 Hz
//     DSP_PLY_BASSBOOST_Q = 2.5
//     DSP_PLY_BASSBOOST_MAX_VALUE = 15 dB
// ─────────────────────────────────────────────────────────────────────

import Foundation
import Accelerate
import Darwin

final class FXProcessor: @unchecked Sendable {

    // MARK: - Constants (directly from FXSound source)
    private static let auralMaxDrive: Float  = Float(Double.pi / 2.0 * 1.8 * 2.0 * 0.75 * 0.8) // 3.393
    private static let auralOdd:  Float      = (53.0 / 127.0) * 1.5          // ≈ 0.626
    private static let auralEven: Float      = 0.75 - (53.0 / 127.0) * 0.75  // ≈ 0.437
    private static let auralHPFHz: Double    = 500.0 + (53.0/127.0) * (10000.0 - 500.0) // ≈ 4460 Hz

    private static let ambienceWet: Float    = 0.21 * 1.3   // 0.273 — FXSound fixed
    private static let ambienceDry: Float    = 0.69 * 1.3   // 0.897 — FXSound fixed

    private static let widenMaxIntensity: Float = 1.0 * 0.7 // DSP_WID_INTENSITY_MAX*PLY_WIDENER_BOOST_MAX_SCALE

    private static let bassMaxDB: Float      = 15.0          // DSP_PLY_BASSBOOST_MAX_VALUE
    private static let bassHz:    Double     = 90.0          // DSP_PLY_BASSBOOST_CENTER_FREQ
    private static let bassQ:     Double     = 2.5           // DSP_PLY_BASSBOOST_Q

    // Max dynamic boost after FXSound scaling:
    // user→MIDI, ×PLY_OPTIMIZER_BOOST_MAX_SCALE(0.7), ×MUSIC_MODE2_FACTOR(1.8), cap 127
    // → maps to DSP_MAXIMIZE_GAIN_BOOST_MAX_VALUE = 30 dB
    // Effective user-10 boost ≈ 21 dB (0.7 * 30)
    private static let boostMaxDB: Float     = 21.0

    // Schroeder reverb delay lengths at 44.1 kHz (scale to actual SR at init)
    private static let combDelays44100  = [1116, 1188, 1277, 1356]
    private static let allpassDelays44100 = [225, 556]
    private static let allpassFeedback: Float = 0.5  // Classic Schroeder value

    // Comb delay buffer max size (handles up to 192 kHz: 1356 * 192000/44100 ≈ 5895)
    private static let maxCombSamples   = 8192
    private static let maxAllpassSamples = 2048
    private static let numCombs = 4
    private static let numAllpass = 2

    // MARK: - Shared state (RT-thread access)
    private nonisolated(unsafe) var enabled = true

    // Clarity
    private nonisolated(unsafe) var clarityDrive: Float = 0
    // HPF biquad coefficients [b0, b1, b2, a1, a2] stored for per-sample processing
    private nonisolated(unsafe) var hpfB0: Float = 0, hpfB1: Float = 0, hpfB2: Float = 0
    private nonisolated(unsafe) var hpfA1: Float = 0, hpfA2: Float = 0
    // HPF delay state — separate for L and R
    private nonisolated(unsafe) var hpf_xL1: Float = 0, hpf_xL2: Float = 0, hpf_yL1: Float = 0, hpf_yL2: Float = 0
    private nonisolated(unsafe) var hpf_xR1: Float = 0, hpf_xR2: Float = 0, hpf_yR1: Float = 0, hpf_yR2: Float = 0

    // Ambience
    private nonisolated(unsafe) var ambienceWetGain: Float = 0   // 0 = bypass
    private nonisolated(unsafe) var combFeedback: Float = 0.75
    private nonisolated(unsafe) var combLengths: [Int] = Array(repeating: 1116, count: numCombs)
    private nonisolated(unsafe) var allpassLengths: [Int] = Array(repeating: 225, count: numAllpass)
    private nonisolated(unsafe) var combPosL: [Int]    = Array(repeating: 0, count: numCombs)
    private nonisolated(unsafe) var combPosR: [Int]    = Array(repeating: 0, count: numCombs)
    private nonisolated(unsafe) var apPosL: [Int]      = Array(repeating: 0, count: numAllpass)
    private nonisolated(unsafe) var apPosR: [Int]      = Array(repeating: 0, count: numAllpass)

    // Surround
    private nonisolated(unsafe) var widenIntensity: Float = 0

    // Dynamic boost
    private nonisolated(unsafe) var boostLinear: Float = 1.0
    private nonisolated(unsafe) var envL: Float = 0
    private nonisolated(unsafe) var envR: Float = 0
    private static let envAttack:  Float = 0.9990   // fast attack (~0.75 ms lookahead equivalent)
    private static let envRelease: Float = 0.9999   // slow release (~200 ms)

    // Bass boost — reuse vDSP_biquad for quality
    private nonisolated(unsafe) var bassSetup: vDSP_biquad_Setup? = nil

    // 9-band FX EQ (custom frequencies, ±12 dB)
    // Frequencies: 116, 250, 397, 735, 1360, 2520, 5350, 8640, 13800 Hz
    // Per-band center frequencies come from FXSettings.eqFreqs (set by dials)
    private static let fxEQBandCount = 9
    private static let fxEQQ: Double = 1.4  // Same as BiquadMath.graphicEQQ
    private nonisolated(unsafe) var fxEQSetup: vDSP_biquad_Setup? = nil

    // MARK: - Heap-allocated buffers (RT-safe, allocated once)
    // Reverb comb buffers: [numCombs] × maxCombSamples, L and R
    private let combBufL: [UnsafeMutablePointer<Float>]
    private let combBufR: [UnsafeMutablePointer<Float>]
    // Reverb allpass buffers
    private let apBufL: [UnsafeMutablePointer<Float>]
    private let apBufR: [UnsafeMutablePointer<Float>]
    // Bass biquad delay buffers (2 sections + 2 extra = 4 floats each)
    private let bassDelL: UnsafeMutablePointer<Float>
    private let bassDelR: UnsafeMutablePointer<Float>
    // 9-band FX EQ delay buffers: (2*sections)+2 = 20 floats each channel
    private let fxEQDelL: UnsafeMutablePointer<Float>
    private let fxEQDelR: UnsafeMutablePointer<Float>

    private var sampleRate: Double

    // MARK: - Init
    init(sampleRate: Double) {
        self.sampleRate = sampleRate

        // Allocate comb buffers
        var cbl = [UnsafeMutablePointer<Float>]()
        var cbr = [UnsafeMutablePointer<Float>]()
        for _ in 0..<Self.numCombs {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxCombSamples)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxCombSamples)
            l.initialize(repeating: 0, count: Self.maxCombSamples)
            r.initialize(repeating: 0, count: Self.maxCombSamples)
            cbl.append(l); cbr.append(r)
        }
        combBufL = cbl; combBufR = cbr

        // Allocate allpass buffers
        var abl = [UnsafeMutablePointer<Float>]()
        var abr = [UnsafeMutablePointer<Float>]()
        for _ in 0..<Self.numAllpass {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxAllpassSamples)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxAllpassSamples)
            l.initialize(repeating: 0, count: Self.maxAllpassSamples)
            r.initialize(repeating: 0, count: Self.maxAllpassSamples)
            abl.append(l); abr.append(r)
        }
        apBufL = abl; apBufR = abr

        // Bass biquad delay buffers (1 section needs 4 floats: 2 input + 2 output delay)
        bassDelL = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        bassDelR = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        bassDelL.initialize(repeating: 0, count: 4)
        bassDelR.initialize(repeating: 0, count: 4)
        // 9-band FX EQ: (2*9)+2 = 20 delay samples per channel
        fxEQDelL = UnsafeMutablePointer<Float>.allocate(capacity: 20)
        fxEQDelR = UnsafeMutablePointer<Float>.allocate(capacity: 20)
        fxEQDelL.initialize(repeating: 0, count: 20)
        fxEQDelR.initialize(repeating: 0, count: 20)
    }

    deinit {
        for i in 0..<Self.numCombs  { combBufL[i].deallocate(); combBufR[i].deallocate() }
        for i in 0..<Self.numAllpass { apBufL[i].deallocate(); apBufR[i].deallocate() }
        bassDelL.deallocate(); bassDelR.deallocate()
        fxEQDelL.deallocate(); fxEQDelR.deallocate()
        if let s = bassSetup { vDSP_biquad_DestroySetup(s) }
        if let s = fxEQSetup { vDSP_biquad_DestroySetup(s) }
    }

    // MARK: - Update (main thread)
    func update(_ s: FXSettings, sampleRate sr: Double? = nil) {
        if let sr = sr { sampleRate = sr }
        enabled = s.isEnabled

        // ── Clarity ────────────────────────────────────────────────────────────
        clarityDrive = Float(s.clarity) / 10.0 * Self.auralMaxDrive

        // 2nd-order Butterworth HPF at ~4460 Hz for harmonic filtering
        let fc = Self.auralHPFHz
        let K  = tan(.pi * fc / sampleRate)
        let sqrt2 = 2.0.squareRoot()
        let norm = 1.0 / (1.0 + sqrt2 * K + K * K)
        hpfB0 = Float(norm)
        hpfB1 = Float(-2.0 * norm)
        hpfB2 = Float(norm)
        hpfA1 = Float(2.0 * (K * K - 1.0) * norm)
        hpfA2 = Float((1.0 - sqrt2 * K + K * K) * norm)

        // ── Ambience ────────────────────────────────────────────────────────────
        if s.ambience == 0 {
            ambienceWetGain = 0
        } else {
            ambienceWetGain = Self.ambienceWet
            // Scale comb feedback for RT60 from 0.3 s (user=1) to 1.5 s (user=10)
            let rt60 = 0.3 + Double(s.ambience - 1) / 9.0 * 1.2  // 0.3 → 1.5 s
            // g = 10^(-3*D / (RT60 * sr)) where D is the longest comb delay in samples
            let D = Self.combDelays44100[3]
            let combSamples = Int(Double(D) * sampleRate / 44100.0)
            let g = pow(10.0, -3.0 * Double(combSamples) / (rt60 * sampleRate))
            combFeedback = Float(min(0.93, max(0.3, g)))

            // Scale delay lengths to current sample rate
            for i in 0..<Self.numCombs {
                combLengths[i] = max(1, min(Self.maxCombSamples - 1,
                    Int(Double(Self.combDelays44100[i]) * sampleRate / 44100.0)))
            }
            for i in 0..<Self.numAllpass {
                allpassLengths[i] = max(1, min(Self.maxAllpassSamples - 1,
                    Int(Double(Self.allpassDelays44100[i]) * sampleRate / 44100.0)))
            }
        }

        // ── Surround ────────────────────────────────────────────────────────────
        widenIntensity = Float(s.surroundSound) / 10.0 * Self.widenMaxIntensity

        // ── Dynamic Boost ───────────────────────────────────────────────────────
        let boostDB = Float(s.dynamicBoost) / 10.0 * Self.boostMaxDB
        boostLinear = pow(10.0, boostDB / 20.0)

        // ── Bass Boost ──────────────────────────────────────────────────────────
        let gainDB = Float(s.bassBoost) / 10.0 * Self.bassMaxDB
        if let old = bassSetup { vDSP_biquad_DestroySetup(old) }
        if gainDB > 0 {
            let coeffs = BiquadMath.peakingEQCoefficients(
                frequency: Self.bassHz, gainDB: gainDB, q: Self.bassQ, sampleRate: sampleRate)
            let cs = coeffs
            bassSetup = cs.withUnsafeBufferPointer {
                vDSP_biquad_CreateSetup($0.baseAddress!, 1)
            }
        } else {
            bassSetup = nil
        }

        // ── 9-band FX EQ ─────────────────────────────────────────────────────────
        if let old = fxEQSetup { vDSP_biquad_DestroySetup(old) }
        let hasEQ = s.eqGains.contains(where: { $0 != 0 })
        if hasEQ {
            var allCoeffs = [Double]()
            allCoeffs.reserveCapacity(Self.fxEQBandCount * 5)
            let nyquist = sampleRate / 2.0
            for i in 0..<Self.fxEQBandCount {
                let freq = i < s.eqFreqs.count ? s.eqFreqs[i] : 1000.0
                if freq >= nyquist {
                    allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                } else {
                    let coeffs = BiquadMath.peakingEQCoefficients(
                        frequency: freq, gainDB: i < s.eqGains.count ? s.eqGains[i] : 0,
                        q: Self.fxEQQ, sampleRate: sampleRate)
                    allCoeffs.append(contentsOf: coeffs)
                }
            }
            fxEQSetup = allCoeffs.withUnsafeBufferPointer {
                vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(Self.fxEQBandCount))
            }
        } else {
            fxEQSetup = nil
        }
    }

    func updateSampleRate(_ sr: Double) {
        guard sr != sampleRate else { return }
        sampleRate = sr
        // Reset reverb buffers on SR change to avoid pitched artifacts
        for i in 0..<Self.numCombs {
            combBufL[i].initialize(repeating: 0, count: Self.maxCombSamples)
            combBufR[i].initialize(repeating: 0, count: Self.maxCombSamples)
            combPosL[i] = 0; combPosR[i] = 0
        }
        for i in 0..<Self.numAllpass {
            apBufL[i].initialize(repeating: 0, count: Self.maxAllpassSamples)
            apBufR[i].initialize(repeating: 0, count: Self.maxAllpassSamples)
            apPosL[i] = 0; apPosR[i] = 0
        }
        bassDelL.initialize(repeating: 0, count: 4)
        bassDelR.initialize(repeating: 0, count: 4)
        fxEQDelL.initialize(repeating: 0, count: 20)
        fxEQDelR.initialize(repeating: 0, count: 20)
    }

    // MARK: - Process (audio RT thread, stereo interleaved)
    /// Process interleaved stereo float buffer in-place.
    /// frameCount = number of stereo frames (totalSamples / channels)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        guard enabled else { return }
        let stereo = (channelCount >= 2)

        for f in 0..<frameCount {
            let li = stereo ? f * 2     : f
            let ri = stereo ? f * 2 + 1 : f

            var L = buffer[li]
            var R = stereo ? buffer[ri] : L

            // ── 1. Clarity ──────────────────────────────────────────────────
            if clarityDrive > 0 {
                let dL = clarityDrive * L
                let dR = clarityDrive * R
                // Harmonic generation
                let hL = Self.auralOdd * sinf(dL) + Self.auralEven * (1.0 - cosf(dL))
                let hR = Self.auralOdd * sinf(dR) + Self.auralEven * (1.0 - cosf(dR))
                // 2nd-order Butterworth HPF on harmonics
                let yL = hpfB0*hL + hpfB1*hpf_xL1 + hpfB2*hpf_xL2 - hpfA1*hpf_yL1 - hpfA2*hpf_yL2
                let yR = hpfB0*hR + hpfB1*hpf_xR1 + hpfB2*hpf_xR2 - hpfA1*hpf_yR1 - hpfA2*hpf_yR2
                hpf_xL2 = hpf_xL1; hpf_xL1 = hL; hpf_yL2 = hpf_yL1; hpf_yL1 = yL
                hpf_xR2 = hpf_xR1; hpf_xR1 = hR; hpf_yR2 = hpf_yR1; hpf_yR1 = yR
                // Mix exciter back (FXSound adds harmonics on top of dry signal)
                L += yL
                R += yR
            }

            // ── 2. Ambience ──────────────────────────────────────────────────
            if ambienceWetGain > 0 {
                // 4 parallel comb filters → sum → 2 series allpass
                var reverbL: Float = 0
                var reverbR: Float = 0
                let fb = combFeedback

                for c in 0..<Self.numCombs {
                    let len = combLengths[c]
                    let posL = combPosL[c]
                    let posR = combPosR[c]
                    let outL = combBufL[c][posL]
                    let outR = combBufR[c][posR]
                    combBufL[c][posL] = L + fb * outL
                    combBufR[c][posR] = R + fb * outR
                    combPosL[c] = (posL + 1) % len
                    combPosR[c] = (posR + 1) % len
                    reverbL += outL
                    reverbR += outR
                }
                reverbL *= 0.25  // normalize 4 combs
                reverbR *= 0.25

                // 2 allpass diffusers (in series)
                for a in 0..<Self.numAllpass {
                    let len = allpassLengths[a]
                    let posL = apPosL[a]
                    let posR = apPosR[a]
                    let bufL = apBufL[a][posL]
                    let bufR = apBufR[a][posR]
                    let apfb = Self.allpassFeedback
                    let outL = -apfb * reverbL + bufL
                    let outR = -apfb * reverbR + bufR
                    apBufL[a][posL] = reverbL + apfb * outL
                    apBufR[a][posR] = reverbR + apfb * outR
                    apPosL[a] = (posL + 1) % len
                    apPosR[a] = (posR + 1) % len
                    reverbL = outL
                    reverbR = outR
                }

                L = Self.ambienceDry * L + ambienceWetGain * reverbL
                R = Self.ambienceDry * R + ambienceWetGain * reverbR
            }

            // ── 3. Surround ──────────────────────────────────────────────────
            if stereo && widenIntensity > 0 {
                let mid  = (L + R) * 0.5
                let side = (L - R) * 0.5
                let w    = 1.0 + widenIntensity  // 1.0 to 1.7
                L = mid + side * w
                R = mid - side * w
            }

            // ── 4. Dynamic Boost ─────────────────────────────────────────────
            if boostLinear > 1.0 {
                let bL = L * boostLinear
                let bR = R * boostLinear
                // Peak envelope follower
                let peakL = abs(bL)
                let peakR = abs(bR)
                envL = peakL > envL ? envL + (peakL - envL) * (1.0 - Self.envAttack)
                                    : envL * Self.envRelease
                envR = peakR > envR ? envR + (peakR - envR) * (1.0 - Self.envAttack)
                                    : envR * Self.envRelease
                // Apply gain reduction if peaks would exceed 0 dBFS
                let gainL: Float = envL > 1.0 ? 1.0 / envL : 1.0
                let gainR: Float = envR > 1.0 ? 1.0 / envR : 1.0
                L = bL * gainL
                R = bR * gainR
            }

            // ── 5. Bass Boost ────────────────────────────────────────────────
            // (applied via vDSP_biquad below, outside the sample loop for efficiency)

            buffer[li] = L
            if stereo { buffer[ri] = R }
        }

        // Bass boost: apply via vDSP_biquad for efficiency (post sample loop)
        if let setup = bassSetup {
            vDSP_biquad(setup, bassDelL, buffer, stereo ? 2 : 1,
                        buffer, stereo ? 2 : 1, vDSP_Length(frameCount))
            if stereo {
                vDSP_biquad(setup, bassDelR, buffer.advanced(by: 1), 2,
                            buffer.advanced(by: 1), 2, vDSP_Length(frameCount))
            }
        }

        // 9-band FX EQ (post-effects graphic EQ)
        if let setup = fxEQSetup {
            vDSP_biquad(setup, fxEQDelL, buffer, stereo ? 2 : 1,
                        buffer, stereo ? 2 : 1, vDSP_Length(frameCount))
            if stereo {
                vDSP_biquad(setup, fxEQDelR, buffer.advanced(by: 1), 2,
                            buffer.advanced(by: 1), 2, vDSP_Length(frameCount))
            }
        }
    }
}
