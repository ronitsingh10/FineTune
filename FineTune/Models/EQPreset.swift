import Foundation

enum EQPreset: String, CaseIterable, Identifiable {
    // Utility
    case flat
    case bassBoost
    case bassCut
    case trebleBoost
    // Speech
    case vocalClarity
    case podcast
    case spokenWord
    // Listening
    case loudness
    case lateNight
    case smallSpeakers
    // Music
    case rock
    case pop
    case electronic
    case jazz
    case classical
    case hipHop
    case rnb
    case deep
    case acoustic
    // Media
    case movie

    var id: String { rawValue }

    // MARK: - Categories

    enum Category: String, CaseIterable, Identifiable {
        case utility = "Utility"
        case speech = "Speech"
        case listening = "Listening"
        case music = "Music"
        case media = "Media"

        var id: String { rawValue }

        var displayName: String { L10n.string(rawValue) }
    }

    var category: Category {
        switch self {
        case .flat, .bassBoost, .bassCut, .trebleBoost:
            return .utility
        case .vocalClarity, .podcast, .spokenWord:
            return .speech
        case .loudness, .lateNight, .smallSpeakers:
            return .listening
        case .rock, .pop, .electronic, .jazz, .classical, .hipHop, .rnb, .deep, .acoustic:
            return .music
        case .movie:
            return .media
        }
    }

    static func presets(for category: Category) -> [EQPreset] {
        allCases.filter { $0.category == category }
    }

    var name: String {
        switch self {
        case .flat: return L10n.string("Flat")
        case .bassBoost: return L10n.string("Bass Boost")
        case .bassCut: return L10n.string("Bass Cut")
        case .trebleBoost: return L10n.string("Treble Boost")
        case .vocalClarity: return L10n.string("Vocal Clarity")
        case .podcast: return L10n.string("Podcast")
        case .spokenWord: return L10n.string("Spoken Word")
        case .loudness: return L10n.string("Loudness")
        case .lateNight: return L10n.string("Late Night")
        case .smallSpeakers: return L10n.string("Small Speakers")
        case .rock: return L10n.string("Rock")
        case .pop: return L10n.string("Pop")
        case .electronic: return L10n.string("Electronic")
        case .jazz: return L10n.string("Jazz")
        case .classical: return L10n.string("Classical")
        case .hipHop: return L10n.string("Hip-Hop")
        case .rnb: return L10n.string("R&B")
        case .deep: return L10n.string("Deep")
        case .acoustic: return L10n.string("Acoustic")
        case .movie: return L10n.string("Movie")
        }
    }

    // Bands: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k
    var settings: EQSettings {
        switch self {
        // MARK: - Utility
        case .flat:
            // All neutral
            return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        case .bassBoost:
            // Boost lows, cut 250Hz to prevent muddiness
            return EQSettings(bandGains: [6, 6, 5, -1, 0, 0, 0, 0, 0, 0])
        case .bassCut:
            // Reduce low end
            return EQSettings(bandGains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0])
        case .trebleBoost:
            // Gentle rise into highs for clarity and air
            return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6])

        // MARK: - Speech
        case .vocalClarity:
            // Cut rumble & muddiness, boost presence (2-4kHz)
            return EQSettings(bandGains: [-4, -2, -1, -3, 0, 2, 4, 4, 1, 0])
        case .podcast:
            // Optimized for speech with some music/effects
            return EQSettings(bandGains: [-6, -4, -2, -1, 0, 2, 4, 3, 1, 0])
        case .spokenWord:
            // Audiobooks, lectures - aggressive bass cut, max intelligibility
            return EQSettings(bandGains: [-8, -6, -3, -2, 0, 2, 4, 4, 2, 0])

        // MARK: - Listening
        case .loudness:
            // "Smile curve" - boost lows & highs for low-volume listening
            return EQSettings(bandGains: [5, 4, 2, 0, -2, -2, 0, 2, 4, 5])
        case .lateNight:
            // Neighbor-friendly: heavy bass cut, presence boost
            return EQSettings(bandGains: [-6, -4, -2, 0, 0, 1, 2, 2, 1, 0])
        case .smallSpeakers:
            // Laptop/MacBook speakers: boost reproducible bass, add clarity
            return EQSettings(bandGains: [3, 4, 5, 2, 0, 1, 2, 2, 1, 0])

        // MARK: - Music
        case .rock:
            // Punchy bass, forward guitars & vocals
            return EQSettings(bandGains: [4, 3, 2, 0, -1, 0, 2, 3, 2, 1])
        case .pop:
            // Bright, punchy, vocal-forward
            return EQSettings(bandGains: [3, 3, 2, 0, -1, 1, 2, 3, 3, 4])
        case .electronic:
            // Heavy sub-bass, scooped mids, crisp highs
            return EQSettings(bandGains: [7, 6, 4, 0, -2, -2, 1, 3, 4, 3])
        case .jazz:
            // Warm lows, smooth mids, gentle highs
            return EQSettings(bandGains: [3, 2, 1, 0, 0, 0, 1, 2, 2, 1])
        case .classical:
            // Nearly flat, gentle high "air" for detail
            return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 1, 2, 2, 2])
        case .hipHop:
            // Heavy sub-bass for 808s, crisp highs for hi-hats
            return EQSettings(bandGains: [6, 5, 4, 0, -1, 0, 2, 3, 4, 3])
        case .rnb:
            // Warm bass, recessed mids, smooth vocals
            return EQSettings(bandGains: [4, 4, 3, 1, -1, 0, 2, 3, 3, 2])
        case .deep:
            // Deep house, ambient, lo-fi: sub-bass, scooped mids
            return EQSettings(bandGains: [5, 6, 4, 1, -2, -2, 0, 1, 2, 1])
        case .acoustic:
            // Warm low-mids, natural sparkle
            return EQSettings(bandGains: [0, 1, 2, 2, 1, 0, 1, 2, 2, 1])

        // MARK: - Media
        case .movie:
            // Cinematic: bass rumble, dialogue clarity, effects detail
            return EQSettings(bandGains: [4, 4, 3, -1, -1, 1, 3, 3, 2, 1])
        }
    }
}
