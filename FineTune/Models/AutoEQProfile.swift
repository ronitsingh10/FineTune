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
    let id: String           // Slug for fetched, UUID for imported
    let name: String         // "Sennheiser HD 600"
    let source: AutoEQSource
    let preampDB: Float      // Negative preamp to prevent clipping
    let filters: [AutoEQFilter]
    /// Measurement source (e.g. "oratory1990", "crinacle"). Nil for imported profiles.
    let measuredBy: String?
    /// Sample rate the filter parameters were optimized for (Hz).
    var optimizedSampleRate: Double

    static let maxFilters = 10

    enum CodingKeys: String, CodingKey {
        case id, name, source, preampDB, filters, measuredBy, optimizedSampleRate
    }

    init(
        id: String, name: String, source: AutoEQSource,
        preampDB: Float, filters: [AutoEQFilter],
        measuredBy: String? = nil,
        optimizedSampleRate: Double = 48000
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.preampDB = preampDB
        self.filters = filters
        self.measuredBy = measuredBy
        self.optimizedSampleRate = optimizedSampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(AutoEQSource.self, forKey: .source)
        preampDB = try container.decode(Float.self, forKey: .preampDB)
        filters = try container.decode([AutoEQFilter].self, forKey: .filters)
        measuredBy = try container.decodeIfPresent(String.self, forKey: .measuredBy)
        optimizedSampleRate = try container.decodeIfPresent(Double.self, forKey: .optimizedSampleRate) ?? 48000
    }
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
            filters: Array(validFilters.prefix(Self.maxFilters)),
            measuredBy: measuredBy,
            optimizedSampleRate: optimizedSampleRate
        )
    }
}

/// Where a profile came from.
enum AutoEQSource: String, Codable {
    case bundled, imported, fetched
}

/// Lightweight catalog entry for the AutoEQ search index (no filter data).
/// Populated from the AutoEQ GitHub INDEX.md.
struct AutoEQCatalogEntry: Codable, Identifiable, Equatable {
    let id: String           // Slugified name
    let name: String         // "AKG K240 Studio"
    let measuredBy: String   // "oratory1990"
    let relativePath: String // "oratory1990/over-ear/AKG K240 Studio"
}

/// Per-device AutoEQ selection (stored in settings).
struct AutoEQSelection: Codable, Equatable {
    let profileID: String
    var isEnabled: Bool
}
