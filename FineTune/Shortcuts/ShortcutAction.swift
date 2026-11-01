// FineTune/Shortcuts/ShortcutAction.swift
import Foundation

/// Actions that can be bound to a user-recordable global keyboard shortcut.
///
/// Adding a new action here is a single enum case + a corresponding arm
/// in `ShortcutsRegistry.dispatch(_:)`. The `rawValue` is the persistence key
/// in `AppSettings.customShortcuts` and must be stable across releases.
enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case togglePopup
    case targetAppVolumeUp = "frontmostAppVolumeUp"
    case targetAppVolumeDown = "frontmostAppVolumeDown"
    case targetAppMuteToggle = "frontmostAppMuteToggle"

    var displayName: LocalizedStringResource {
        switch self {
        case .togglePopup: "Toggle FineTune Popup"
        case .targetAppVolumeUp: "App Volume Up"
        case .targetAppVolumeDown: "App Volume Down"
        case .targetAppMuteToggle: "App Mute"
        }
    }

    /// Whether holding the chord should keep firing the action while held,
    /// matching macOS media-key auto-repeat. Toggles must not repeat
    /// (would flip-flop state every interval).
    var supportsRepeat: Bool {
        switch self {
        case .targetAppVolumeUp, .targetAppVolumeDown: true
        case .togglePopup, .targetAppMuteToggle: false
        }
    }
}
