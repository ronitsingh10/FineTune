import Foundation

/// A user-created EQ preset — a named EQ curve that can be applied to any app.
/// Stored in SettingsManager alongside built-in presets (EQPreset enum) which are not modified.
struct UserEQPreset: Codable, Equatable, Identifiable {
    /// Stable unique identifier for this preset.
    let id: UUID

    /// User-provided display name (e.g., "My Bass Boost", "Studio Monitor Correction").
    var name: String

    /// The EQ band gains for this preset. Reuses the existing EQSettings model.
    /// The `isEnabled` field on EQSettings is ignored for presets — it's per-app state.
    /// When applying a preset to an app, the caller should copy `bandGains` only.
    var settings: EQSettings

    /// When the preset was created (for display ordering).
    let createdAt: Date

    init(id: UUID = UUID(), name: String, settings: EQSettings, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = createdAt
    }
}
