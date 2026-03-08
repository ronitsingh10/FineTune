// FineTune/Audio/FXSettings.swift
import Foundation

// Frequency ranges per band (min Hz, max Hz) — from FXSound dial ranges
let fxEQBandRanges: [(min: Double, max: Double)] = [
    (86,    157),
    (158,   292),
    (293,   540),
    (541,   1000),
    (1010,  1850),
    (1860,  3430),
    (3440,  6350),
    (6360,  11760),
    (11770, 16000)
]

struct FXSettings: Codable, Equatable {
    var isEnabled:     Bool     = true
    var clarity:       Int      = 0
    var ambience:      Int      = 0
    var surroundSound: Int      = 0
    var dynamicBoost:  Int      = 0
    var bassBoost:     Int      = 0
    // Per-band center frequency (Hz) — set by the dials
    var eqFreqs: [Double] = FXPreset.defaultPreset.eqFreqs
    // Per-band gain (dB ±12) — set by dragging dots on the curve
    var eqGains: [Float]  = Array(repeating: 0, count: 9)

    func matchingPreset() -> FXPreset? {
        FXPreset.allCases.first { p in
            let s = p.settings
            return clarity == s.clarity && ambience == s.ambience
                && surroundSound == s.surroundSound && dynamicBoost == s.dynamicBoost
                && bassBoost == s.bassBoost
                && eqFreqs == p.eqFreqs && eqGains == p.eqGains
        }
    }
}

// MARK: - Presets (exact FXSound factory values)
enum FXPreset: String, CaseIterable, Identifiable {
    case general, movies, tv, transcription, music, voice,
         volumeBoost, gaming, classicProcessing, lightProcessing,
         bassBoost, streamingVideo, defaultPreset
    var id: String { rawValue }

    var name: String {
        switch self {
        case .general:          return "General"
        case .movies:           return "Movies"
        case .tv:               return "TV"
        case .transcription:    return "Transcription"
        case .music:            return "Music"
        case .voice:            return "Voice"
        case .volumeBoost:      return "Volume Boost"
        case .gaming:           return "Gaming"
        case .classicProcessing:return "Classic Processing"
        case .lightProcessing:  return "Light Processing"
        case .bassBoost:        return "Bass Boost"
        case .streamingVideo:   return "Streaming Video"
        case .defaultPreset:    return "Default"
        }
    }

    // {Clarity, Ambience, Surround, DynamicBoost, BassBoost}
    var fxValues: (Int, Int, Int, Int, Int) {
        switch self {
        case .general:          return (4, 0, 2, 5, 5)
        case .movies:           return (5, 0, 4, 7, 3)
        case .tv:               return (4, 2, 4, 5, 4)
        case .transcription:    return (8, 0, 0, 9, 6)
        case .music:            return (4, 3, 3, 2, 5)
        case .voice:            return (6, 0, 0, 7, 0)
        case .volumeBoost:      return (3, 0, 2, 8, 3)
        case .gaming:           return (3, 0, 0, 7, 3)
        case .classicProcessing:return (5, 5, 3, 5, 6)
        case .lightProcessing:  return (2, 3, 0, 0, 2)
        case .bassBoost:        return (2, 3, 3, 2, 6)
        case .streamingVideo:   return (3, 0, 3, 4, 3)
        case .defaultPreset:    return (0, 0, 0, 0, 0)
        }
    }

    // Center frequency (Hz) for each of the 9 bands
    var eqFreqs: [Double] {
        switch self {
        case .general:          return [115,  250,  450,  630,  1250, 2700, 5300, 7500,  13000]
        case .movies:           return [116,  250,  397,  735,  1360, 2520, 5350, 8640,  13800]
        case .tv:               return [116,  250,  397,  735,  1360, 2520, 5350, 8640,  13800]
        case .transcription:    return [ 86,  250,  293,  615,  1320, 3430, 4630, 6360,  11770]
        case .music:            return [110,  250,  370,  650,  1200, 2130, 4550, 6850,  16000]
        case .voice:            return [116,  214,  397,  735,  1360, 3430, 5250, 6300,  11770]
        case .volumeBoost:      return [101,  240,  397,  735,  1360, 2520, 4670, 11760, 16000]
        case .gaming:           return [129,  238,  444,  805,  1360, 2520, 4400, 7930,  12570]
        case .classicProcessing:return [116,  214,  397,  735,  1360, 2520, 4670, 8640,  13500]
        case .lightProcessing:  return [116,  214,  397,  735,  1360, 2520, 4670, 8640,  13600]
        case .bassBoost:        return [ 98,  158,  345,  542,  1170, 2520, 4670, 8640,  14650]
        case .streamingVideo:   return [116,  214,  397,  735,  1360, 2520, 5350, 8640,  13800]
        case .defaultPreset:    return [122,  225,  416,  770,  1420, 2640, 4890, 9060,  13890]
        }
    }

    // Gain (dB) for each band — shown on curve, dragged by user
    var eqGains: [Float] {
        switch self {
        case .general:          return [ 0,  1,  2,  0, -1,  0, -1, -2,  0]
        case .movies:           return [ 0,  2,  0,  2,  2,  1, -1,  0,  2]
        case .tv:               return [ 0,  1,  0,  1,  0,  1, -1, -1,  2]
        case .transcription:    return [-12, 7,  2, -1,  7,  0, 10,  3,-12]
        case .music:            return [ 2,  2,  1,  0,  0,  0, -1,  0,  2]
        case .voice:            return [-4, -2,  2,  4,  5,  3,  3,  5,-11]
        case .volumeBoost:      return [ 3,  2,  2,  0,  0,  1,  1,  2,  2]
        case .gaming:           return [ 0,  2,  2,  2,  0, -1, -1,  2,  2]
        case .classicProcessing:return [ 0,  0,  0,  0,  0,  0,  0,  0,  0]
        case .lightProcessing:  return [-1,  1,  1, -1, -1, -2, -1, -1,  1]
        case .bassBoost:        return [ 3,  3,  2,  1, -1, -1, -1, -1,  0]
        case .streamingVideo:   return [ 0,  0,  0,  1,  1,  1, -1,  0,  2]
        case .defaultPreset:    return [ 0,  0,  0,  0,  0,  0,  0,  0,  0]
        }
    }

    var settings: FXSettings {
        let v = fxValues
        return FXSettings(isEnabled: true,
            clarity: v.0, ambience: v.1, surroundSound: v.2,
            dynamicBoost: v.3, bassBoost: v.4,
            eqFreqs: eqFreqs, eqGains: eqGains)
    }
}
