// FineTune/Models/DisplayableApp.swift
import AppKit
import UniformTypeIdentifiers

/// Represents an app that can be displayed in the UI, either active (currently playing audio)
/// or pinned but inactive (not currently running or producing audio).
enum DisplayableApp: Identifiable {
    case active(AudioApp)
    case pinnedInactive(PinnedAppInfo)

    var id: String {
        switch self {
        case .active(let app):
            return app.rowID
        case .pinnedInactive(let info):
            return info.persistenceIdentifier
        }
    }

    /// Whether this represents a pinned-but-inactive app.
    /// Note: Active apps may also be pinned - check the pinned list directly for that case.
    var isPinnedInactive: Bool {
        switch self {
        case .active:
            return false
        case .pinnedInactive:
            return true
        }
    }

    var isActive: Bool {
        switch self {
        case .active:
            return true
        case .pinnedInactive:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .active(let app):
            return app.name
        case .pinnedInactive(let info):
            return info.displayName
        }
    }

    var icon: NSImage {
        switch self {
        case .active(let app):
            return app.icon
        case .pinnedInactive(let info):
            return Self.loadIcon(bundleID: info.bundleID)
        }
    }

    /// Loads the app icon from a bundle ID, or returns a generic placeholder.
    static func loadIcon(bundleID: String?) -> NSImage {
        if let bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
