// FineTune/Models/SemanticVersion.swift
import Foundation

/// A semantic version (major.minor.patch) with comparison support.
/// Handles version strings with or without "v" prefix (e.g., "1.2.0" or "v1.2.0").
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    /// Creates a SemanticVersion from individual components.
    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a version string into a SemanticVersion.
    /// Handles formats: "1.2.3", "v1.2.3", "1.2" (treated as 1.2.0)
    /// Returns nil if the string cannot be parsed.
    init?(_ string: String) {
        // Remove leading "v" or "V" if present
        var versionString = string
        if versionString.lowercased().hasPrefix("v") {
            versionString = String(versionString.dropFirst())
        }

        // Split by "." and parse components
        let components = versionString.split(separator: ".").compactMap { Int($0) }

        guard components.count >= 2 else { return nil }

        self.major = components[0]
        self.minor = components[1]
        self.patch = components.count >= 3 ? components[2] : 0
    }

    // MARK: - Comparable

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }

    // MARK: - Convenience

    /// Returns the current app version from the bundle.
    static var current: SemanticVersion? {
        guard let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return SemanticVersion(versionString)
    }
}
