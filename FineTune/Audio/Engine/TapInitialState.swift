// FineTune/Audio/Engine/TapInitialState.swift
import Foundation

/// Persisted settings applied to a fresh ProcessTapController before its IOProc starts.
struct TapInitialState {
    var eqSettings: EQSettings = .flat
    var autoEQProfile: AutoEQProfile? = nil
    var autoEQPreampEnabled: Bool = false
    /// Listening level for phon estimation: device volume × per-app slider.
    var loudnessVolume: Float = 1.0
    /// Linear gain applied inside the tap before the loudness compensator
    /// (app volume × boost × software device gain) — the digital headroom it may use.
    var loudnessDigitalGain: Float = 1.0
    var loudnessCompensationEnabled: Bool = false
    var loudnessEqualizerSettings: LoudnessEqualizerSettings = .init()
}
