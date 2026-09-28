// FineTune/Audio/Engine/TapInitialState.swift
import Foundation

/// Persisted settings applied to a fresh ProcessTapController before its IOProc starts.
struct TapInitialState {
    var eqSettings: EQSettings = .flat
    var autoEQProfile: AutoEQProfile? = nil
    var autoEQPreampEnabled: Bool = false
    var loudnessVolume: Float = 1.0
    var loudnessCompensationEnabled: Bool = false
    var loudnessEqualizerSettings: LoudnessEqualizerSettings = .init()
    /// Per-app mono mode — downmix this app's audio and duplicate to both channels.
    var monoDownmix: Bool = false
}
