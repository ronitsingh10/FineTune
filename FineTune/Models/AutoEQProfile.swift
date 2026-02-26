// FineTune/Models/AutoEQProfile.swift

/// A single biquad filter in an AutoEQ correction profile.
struct AutoEQFilter: Codable, Equatable {
    enum FilterType: String, Codable {
        case peaking, lowShelf, highShelf
    }
    let type: FilterType
    let frequency: Double    // Hz
    let gainDB: Float        // dB
    let q: Double            // Quality factor
}

/// A headphone/speaker correction profile from AutoEQ.
struct AutoEQProfile: Codable, Equatable, Identifiable {
    let id: String           // Slug for bundled, UUID for imported
    let name: String         // "Sennheiser HD 600"
    let source: AutoEQSource
    let preampDB: Float      // Negative preamp to prevent clipping
    let filters: [AutoEQFilter]

    static let maxFilters = 10
}

extension AutoEQProfile {
    /// Validates filters using the same rules as the text parser.
    func validated() -> AutoEQProfile {
        let validFilters = filters.filter { f in
            f.frequency > 0 && f.q > 0 && abs(f.gainDB) <= 30
        }
        let clampedPreamp = max(-30, min(30, preampDB))
        return AutoEQProfile(
            id: id, name: name, source: source,
            preampDB: clampedPreamp,
            filters: Array(validFilters.prefix(Self.maxFilters))
        )
    }
}

/// Where a profile came from.
enum AutoEQSource: String, Codable {
    case bundled, imported
}

/// Per-device AutoEQ selection (stored in settings).
struct AutoEQSelection: Codable, Equatable {
    let profileID: String
    var isEnabled: Bool
}
