// FineTune/Models/MenuBarIconOption.swift
import Foundation

/// Available menu bar icon options for the app
enum MenuBarIconOption: String, Codable, CaseIterable {
    case `default` = "default"
    case speaker = "speaker"
    case waveform = "waveform"
    case equalizer = "equalizer"
    case musicNote = "musicNote"

    /// Display name shown in the settings picker
    var displayName: String {
        switch self {
        case .default:
            return "Default"
        case .speaker:
            return "Speaker"
        case .waveform:
            return "Waveform"
        case .equalizer:
            return "Equalizer"
        case .musicNote:
            return "Music Note"
        }
    }

    /// The image name (SF Symbol name or asset name)
    var imageName: String {
        switch self {
        case .default:
            return "MenuBarIcon"
        case .speaker:
            return "speaker.wave.2.fill"
        case .waveform:
            return "waveform"
        case .equalizer:
            return "slider.vertical.3"
        case .musicNote:
            return "music.note"
        }
    }

    /// Whether this option uses an SF Symbol (true) or a custom asset (false)
    var isSystemImage: Bool {
        switch self {
        case .default:
            return false
        case .speaker, .waveform, .equalizer, .musicNote:
            return true
        }
    }
}
