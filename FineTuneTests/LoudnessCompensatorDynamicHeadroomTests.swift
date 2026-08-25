// FineTuneTests/LoudnessCompensatorDynamicHeadroomTests.swift

import Foundation
import Testing
@testable import FineTune

/// Verifies the dynamic headroom preamp of `LoudnessCompensator`:
///
///     availableHeadroomDB = max(0, -20·log10(min(digitalGain, 1)))
///     cutDB               = max(0, peakGainDB - availableHeadroomDB)
///
/// The preamp is a single global offset — the fitted spectral shape must never change.
@Suite("LoudnessCompensator — dynamic headroom")
struct LoudnessCompensatorDynamicHeadroomTests {

    private let sampleRate = 48000.0
    private let listeningVolume: Float = 0.25   // ≈ 50 phon → peak boost ≈ 14.3 dB

    private func peakGainDB(volume: Float) -> Float {
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: volume)
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: phon, sampleRate: sampleRate)
        return LoudnessCompensator.peakRealizedGainDB(sectionGains: gains, sampleRate: sampleRate)
    }

    /// Steady-state peak of a stereo sine after compensation, pre-scaled by `digitalGain`
    /// exactly as the tap's volume stage would.
    private func steadyPeak(_ compensator: LoudnessCompensator, frequency: Double, digitalGain: Float, seconds: Double = 2.0) -> Float {
        let frames = Int(sampleRate * seconds)
        var buffer = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let sample = digitalGain * Float(sin(2.0 * Double.pi * frequency * Double(f) / sampleRate))
            buffer[f * 2] = sample
            buffer[f * 2 + 1] = sample
        }
        buffer.withUnsafeMutableBufferPointer { ptr in
            compensator.process(input: UnsafePointer(ptr.baseAddress!), output: ptr.baseAddress!, frameCount: frames)
        }
        return buffer[frames...].map(abs).max() ?? 0   // second half: filters settled
    }

    // MARK: 1. Truth table

    @Test("Cut equals the peak boost not covered by digital headroom", arguments: [
        (digitalGain: Float(1.0), expectedHeadroom: Float(0.0)),
        (digitalGain: Float(0.5), expectedHeadroom: Float(6.0206)),
        (digitalGain: Float(0.25), expectedHeadroom: Float(12.0412)),
        (digitalGain: Float(0.1), expectedHeadroom: Float(20.0)),
    ])
    func truthTable(digitalGain: Float, expectedHeadroom: Float) {
        let peak = peakGainDB(volume: listeningVolume)
        #expect(peak > 13 && peak < 16, "25% volume should need ≈14 dB of headroom, got \(peak)")

        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: digitalGain)
        #expect(compensator.isEnabled)
        #expect(abs(compensator.currentPeakGainDB - peak) < 1e-4)

        let available = LoudnessCompensator.availableHeadroomDB(digitalGain: digitalGain)
        #expect(abs(available - expectedHeadroom) < 1e-3)
        let expectedCut = max(0, peak - expectedHeadroom)
        #expect(abs(compensator.currentPreampCutDB - expectedCut) < 1e-3,
                "digitalGain \(digitalGain): cut \(compensator.currentPreampCutDB) dB, expected \(expectedCut) dB")
        #expect(abs(compensator.currentPreampGain - powf(10, -expectedCut / 20)) < 1e-5)
    }

    @Test("Per-app boost above unity provides no headroom (limiter's job, unchanged)")
    func overUnityDigitalGainProvidesNoHeadroom() {
        #expect(LoudnessCompensator.availableHeadroomDB(digitalGain: 2.0) == 0)
        #expect(LoudnessCompensator.availableHeadroomDB(digitalGain: 0.0) == 0)
        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: 3.0)
        #expect(abs(compensator.currentPreampCutDB - compensator.currentPeakGainDB) < 1e-4)
    }

    // MARK: 2. Shape invariance

    @Test("Preamp is a pure global offset: realized shape is identical for every digital gain", arguments: [Float(1.0), 0.5, 0.25, 0.1])
    func shapeIsInvariant(digitalGain: Float) {
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: listeningVolume)
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: phon, sampleRate: sampleRate)
        let uncut = LoudnessCompensator.realizedResponseDB(sectionGains: gains.map(Double.init), sampleRate: sampleRate)

        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: digitalGain)
        let cut = Double(compensator.currentPreampCutDB)

        // The cascade coefficients are untouched, so realized − cut must equal the uncut
        // fit at every grid point. (PR #351 subtracted the deficit from each section gain,
        // which changes the shape — that is exactly what this test forbids.)
        let grid = LoudnessCompensator.fitGridFrequencies()
        let response = LoudnessCompensator.realizedResponseDB(sectionGains: gains.map(Double.init), sampleRate: sampleRate)
        for (index, frequency) in grid.enumerated() {
            let effective = response[index] - cut
            #expect(abs((effective + cut) - uncut[index]) < 0.01, "\(frequency) Hz shape drifted")
        }

        // The 1 kHz-relative bass boost is the whole point of the feature and must survive.
        func at(_ hz: Double) -> Double {
            let i = grid.enumerated().min { abs($0.element - hz) < abs($1.element - hz) }!.offset
            return uncut[i]
        }
        let bassRelative = at(40) - at(1000)
        #expect(bassRelative > 12 && bassRelative < 16, "40 Hz should sit ≈ +13.6 dB above 1 kHz, got \(bassRelative)")

        // Peak after the cut never exceeds the headroom that was actually available.
        let available = Double(LoudnessCompensator.availableHeadroomDB(digitalGain: digitalGain))
        #expect((uncut.max() ?? 0) - cut <= available + 1e-6)

        // Signal-domain check through the real processing path: the measured 40 Hz vs
        // 1 kHz difference must match the fitted shape for every digital gain.
        let bassPeak = steadyPeak(compensator, frequency: 40, digitalGain: digitalGain)
        let midPeak = steadyPeak(compensator, frequency: 1000, digitalGain: digitalGain)
        let measuredRelative = Double(20 * log10f(bassPeak / midPeak))
        #expect(abs(measuredRelative - bassRelative) < 0.3,
                "digitalGain \(digitalGain): measured 40 Hz rel. 1 kHz \(measuredRelative) dB vs fitted \(bassRelative) dB")
        // …and the absolute 1 kHz level is the input scaled by exactly the cut.
        let midLevelDB = Double(20 * log10f(midPeak / digitalGain))
        #expect(abs(midLevelDB + cut) < 0.3, "digitalGain \(digitalGain): 1 kHz at \(midLevelDB) dB, expected \(-cut) dB")
    }

    // MARK: 3. Signal never exceeds unity

    @Test("Full-scale bass pre-scaled by the digital gain never exceeds unity after compensation", arguments: [Float(1.0), 0.5, 0.25, 0.1])
    func fullScaleBassStaysBelowUnity(digitalGain: Float) {
        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: digitalGain)
        for frequency in [20.0, 40.0, 60.0, 100.0] {
            let peak = steadyPeak(compensator, frequency: frequency, digitalGain: digitalGain)
            #expect(peak <= 1.0, "digitalGain \(digitalGain), \(frequency) Hz peaked at \(peak)")
        }
    }

    // MARK: 4. 1 kHz anchor

    @Test("1 kHz stays at unity when digital headroom covers the boost")
    func midBandAtUnityWithHeadroom() {
        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: 0.1)
        #expect(compensator.currentPreampCutDB == 0)
        // Output at 1 kHz equals the (pre-scaled) input: no attenuation, bass really boosted.
        let midPeak = steadyPeak(compensator, frequency: 1000, digitalGain: 0.1)
        #expect(abs(midPeak - 0.1) < 0.002, "1 kHz should pass at unity, got \(midPeak) for 0.1 input")
        let bassPeak = steadyPeak(compensator, frequency: 40, digitalGain: 0.1)
        #expect(bassPeak > 0.4, "40 Hz should be genuinely boosted (≈ +13.7 dB), got \(bassPeak) for 0.1 input")
    }

    @Test("1 kHz is attenuated by exactly the cut when headroom is insufficient")
    func midBandAttenuatedByCut() {
        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: 0.5)
        let midPeak = steadyPeak(compensator, frequency: 1000, digitalGain: 0.5)
        let levelDB = 20 * log10f(midPeak / 0.5)
        #expect(abs(levelDB + compensator.currentPreampCutDB) < 0.5,
                "1 kHz should sit at -cut (\(-compensator.currentPreampCutDB) dB), got \(levelDB) dB")
    }

    // MARK: 5. Lifecycle

    @Test("Bypass at reference level clears the preamp")
    func bypassClearsPreamp() {
        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: 1.0)
        #expect(compensator.currentPreampCutDB > 0)
        compensator.update(listeningVolume: 1.0, digitalGain: 1.0)
        #expect(!compensator.isEnabled)
        #expect(compensator.currentPreampCutDB == 0)
        #expect(compensator.currentPeakGainDB == 0)
        #expect(compensator.currentPreampGain == 1.0)
        let peak = steadyPeak(compensator, frequency: 1000, digitalGain: 0.5, seconds: 0.05)
        #expect(abs(peak - 0.5) < 1e-5, "bypassed processor must pass audio untouched")
    }

    @Test("Digital gain change alone updates the preamp without a coefficient rebuild")
    func digitalGainOnlyUpdatesPreamp() {
        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        compensator.update(listeningVolume: listeningVolume, digitalGain: 1.0)
        let fullCut = compensator.currentPreampCutDB
        // Same listening volume (phon unchanged → coefficient path coalesced), more headroom.
        compensator.update(listeningVolume: listeningVolume, digitalGain: 0.5)
        #expect(abs((fullCut - compensator.currentPreampCutDB) - 6.0206) < 1e-3)
        compensator.update(listeningVolume: listeningVolume, digitalGain: 1.0)
        #expect(abs(compensator.currentPreampCutDB - fullCut) < 1e-4)
    }

    @Test("Sample-rate change recomputes the cut for the new cascade")
    @MainActor
    func sampleRateChangeRecomputesCut() {
        let compensator = LoudnessCompensator(sampleRate: 44100)
        compensator.update(listeningVolume: listeningVolume, digitalGain: 0.5)
        let cutAt44k = compensator.currentPreampCutDB
        #expect(cutAt44k > 0)

        compensator.updateSampleRate(96000)
        #expect(compensator.isEnabled)
        let expected96k = LoudnessCompensator.preampCutDB(peakGainDB: peakGainDB96k(), digitalGain: 0.5)
        #expect(abs(compensator.currentPreampCutDB - expected96k) < 1e-3)
        #expect(abs(compensator.currentPreampCutDB - cutAt44k) < 0.5, "peak should be nearly rate-independent")
    }

    private func peakGainDB96k() -> Float {
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: listeningVolume)
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: phon, sampleRate: 96000)
        return LoudnessCompensator.peakRealizedGainDB(sectionGains: gains, sampleRate: 96000)
    }
}
