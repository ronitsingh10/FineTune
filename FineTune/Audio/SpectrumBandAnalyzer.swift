// FineTune/Audio/SpectrumBandAnalyzer.swift
//
// 10-band spectrum analyser using the exact resonant bandpass filter design
// from FxSound's spectrumReset.cpp.
//
// Filters are 2-pole resonant IIR, designed for 48 kHz. The input is the
// difference signal (in - in_2) which acts as a natural high-pass pre-filter.
// Per-band energy is tracked as a leaky mean-square with alpha = exp(-10/fs).
// Output levels are in 0…1 with an empirical ceiling of SPECTRUM_MAX_OUTPUT_VALUE.
//
// Call processBlock() from the audio render callback (any thread).
// Read snapshotBandLevels() from any thread. We intentionally avoid exposing a
// mutable Array across threads, because concurrent Array read/write can trap.

import Foundation

// MARK: - Filter state (one per band)

private struct BandFilter {
    var y1:              Float = 0
    var y2:              Float = 0
    var squaredFiltered: Float = 0
    var level:           Float = 0
    let a1:              Float
    let a2:              Float
    let gain:            Float
}

// MARK: - Analyser

final class SpectrumBandAnalyzer {

    static let bandCount = 10

    /// Published levels read by UI thread.
    /// Kept as fixed fields (not Array) so render thread writes and UI reads do
    /// not race through Swift Array storage/exclusivity.
    private struct PublishedBands {
        var b0: Float = 0; var b1: Float = 0; var b2: Float = 0; var b3: Float = 0; var b4: Float = 0
        var b5: Float = 0; var b6: Float = 0; var b7: Float = 0; var b8: Float = 0; var b9: Float = 0
    }
    private var publishedBands = PublishedBands()

    // Filter states — only accessed from the render callback
    private var filters: [BandFilter]
    private var in1: Float = 0
    private var in2: Float = 0

    // Smoothing alpha for the leaky mean-square envelope (time constant = 10 / sampleRate).
    // Pre-computed for 48 kHz; updated if a different rate is seen.
    private var alpha:       Float = 0
    private var oneMinusAlpha: Float = 0
    private var sampleRate:  Float = 0

    // Sample-rate reduction: FXSound processes at max 48 kHz internally
    private var rateRatio:   Int = 1

    init() {
        // Coefficients and gain denominators from FxSound spectrumReset.cpp (stereo, sensitivity=1.0).
        // Gains are pre-divided by num_channels (2) and gain_denominator.
        let raw: [(a1: Float, a2: Float, warp: Float, gainDenom: Float)] = [
            ( 1.9952707978, -0.9953348411, 0.6, 4.245657595e+02),
            ( 1.9915173377, -0.9917194870, 0.6, 2.391965397e+02),
            ( 1.9846835136, -0.9853206989, 1.0, 1.349296378e+02),
            ( 1.9720410075, -0.9740444157, 1.0, 7.631087758e+01),
            ( 1.9480305935, -0.9543009461, 1.3, 4.334342216e+01),
            ( 1.9006550741, -0.9201218454, 1.3, 2.479951362e+01),
            ( 1.8025225345, -0.8620772515, 1.3, 1.436694455e+01),
            ( 1.5891186613, -0.7664106181, 1.3, 8.490790030e+00),
            ( 1.1149497494, -0.6153052550, 1.5, 5.169741233e+00),
            ( 0.1311997923, -0.3874425954, 1.5, 3.264452631e+00),
        ]
        filters = raw.map { r in
            BandFilter(a1:   r.a1,
                       a2:   r.a2,
                       gain: r.warp / (2.0 * r.gainDenom))   // 2.0 = num_channels
        }
    }

    // MARK: - Render-thread processing

    /// Process one buffer of interleaved stereo (or mono) Float32 samples.
    /// sampleRate: the buffer's sample rate in Hz.
    func processBlock(_ samples: UnsafePointer<Float>,
                      frameCount: Int,
                      channelCount: Int,
                      sampleRate: Float) {
        updateSampleRate(sampleRate)
        let step = rateRatio * channelCount

        var i = 0
        while i < frameCount * channelCount {
            // Sum stereo to mono
            let s: Float = channelCount == 2 ? samples[i] + samples[i + 1] : samples[i]
            i += step

            // Difference signal (FXSound's high-pass pre-filter)
            let diff = s - in2
            in2 = in1
            in1 = s

            // Update all 10 resonant filters
            for b in 0..<SpectrumBandAnalyzer.bandCount {
                filters[b].updateWith(diff, alpha: alpha, oneMinusAlpha: oneMinusAlpha)
            }
        }

        // Publish levels without mutating shared Array storage.
        publishedBands.b0 = filters[0].level
        publishedBands.b1 = filters[1].level
        publishedBands.b2 = filters[2].level
        publishedBands.b3 = filters[3].level
        publishedBands.b4 = filters[4].level
        publishedBands.b5 = filters[5].level
        publishedBands.b6 = filters[6].level
        publishedBands.b7 = filters[7].level
        publishedBands.b8 = filters[8].level
        publishedBands.b9 = filters[9].level
    }

    func reset() {
        for b in 0..<SpectrumBandAnalyzer.bandCount {
            filters[b].y1 = 0; filters[b].y2 = 0
            filters[b].squaredFiltered = 0; filters[b].level = 0
        }
        in1 = 0; in2 = 0
        publishedBands = PublishedBands()
    }

    /// Thread-safe snapshot for UI/engine reads.
    func snapshotBandLevels() -> [Float] {
        let bands = publishedBands
        return [bands.b0, bands.b1, bands.b2, bands.b3, bands.b4,
                bands.b5, bands.b6, bands.b7, bands.b8, bands.b9]
    }

    // MARK: - Private

    private func updateSampleRate(_ sr: Float) {
        guard sr != sampleRate, sr > 0 else { return }
        sampleRate = sr
        // FXSound caps internal rate at 48 kHz
        let internalRate: Float
        if sr > 88200 { internalRate = sr / 4 ; rateRatio = 4 }
        else if sr > 48000 { internalRate = sr / 2 ; rateRatio = 2 }
        else { internalRate = sr ; rateRatio = 1 }
        let a = expf(-10.0 / internalRate)   // time constant = 10
        alpha = a
        oneMinusAlpha = 1.0 - a
    }
}

// MARK: - BandFilter update (inline)

private extension BandFilter {
    mutating func updateWith(_ input: Float, alpha: Float, oneMinusAlpha: Float) {
        // 2-pole resonant filter: out = input + a1*y1 + a2*y2
        let out = input + a1 * y1 + a2 * y2 + 1.0e-5   // bias eliminates underflow
        y2 = y1
        y1 = out
        let scaled = out * gain

        // Leaky mean-square envelope
        squaredFiltered = oneMinusAlpha * (scaled * scaled) + alpha * squaredFiltered

        // Fast integer sqrt approximation (FXSound's exact bit-manipulation)
        // FXSound fast integer sqrt (bit-manipulation approximation, ~6% error)
        let step1 = Int32(bitPattern: squaredFiltered.bitPattern) - (1 << 23)
        let step2 = UInt32(bitPattern: step1 >> 1) &+ (1 << 29)
        level = squaredFiltered > 1.0 ? 1.0 : Float(bitPattern: step2)
    }
}
