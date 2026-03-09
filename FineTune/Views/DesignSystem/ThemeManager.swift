// FineTune/Views/DesignSystem/ThemeManager.swift
import SwiftUI
import AppKit
import Observation

/// App-wide theme. Inject at the root with .environment(themeManager)
/// and read in child views with @Environment(ThemeManager.self).
///
/// - primaryColor / accentColor: the user-chosen hue used for sliders, fills, dots
/// - isDarkMode:    dark or light background
/// - isHiContrast:  true  → vivid primary, grey/white cell borders, plain dark or light bg
///                  false → desaturated primary, primary-tinted borders, pastel-tinted bg
@Observable
final class ThemeManager {

    // MARK: - Stored (persisted) properties

    var hue:        Double = 0.583 { didSet { save() } }   // default ≈ macOS blue
    var saturation: Double = 0.80  { didSet { save() } }
    var brightness: Double = 1.00  { didSet { save() } }
    var isDarkMode:  Bool  = true  { didSet { save() } }
    var isHiContrast: Bool = true  { didSet { save() } }

    // MARK: - Init (loads from UserDefaults)

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "theme.hue")        != nil { hue        = d.double(forKey: "theme.hue") }
        if d.object(forKey: "theme.sat")        != nil { saturation = d.double(forKey: "theme.sat") }
        if d.object(forKey: "theme.bri")        != nil { brightness = d.double(forKey: "theme.bri") }
        if d.object(forKey: "theme.dark")       != nil { isDarkMode  = d.bool(forKey: "theme.dark") }
        if d.object(forKey: "theme.hiContrast") != nil { isHiContrast = d.bool(forKey: "theme.hiContrast") }
    }

    // MARK: - Derived: accent

    /// Raw primary colour chosen by the user (full saturation).
    var primaryColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Accent used for interactive elements (slider fills, dots, active states).
    /// Hi-contrast → vivid.  Lo-contrast → desaturated/pastel.
    var accentColor: Color {
        isHiContrast
            ? primaryColor
            : Color(hue: hue, saturation: saturation * 0.45,
                    brightness: min(1.0, brightness * 1.08))
    }

    // MARK: - Derived: background

    /// Overlay tint applied over the blur material for the popup background.
    ///
    /// Hi-contrast dark  → black 40% (original behaviour)
    /// Hi-contrast light → white 8%
    /// Lo-contrast       → pastel tint derived from the user's hue/sat/bri
    var backgroundOverlayColor: Color {
        guard isHiContrast else {
            // Scale the user's chosen saturation and brightness down to a background-suitable range.
            // Dark:  low brightness, moderate saturation → deep tinted dark
            // Light: high brightness, low saturation → pale pastel
            let bgSat = isDarkMode
                ? saturation * 0.55        // e.g. sat=0.8 → 0.44
                : saturation * 0.28        // e.g. sat=0.8 → 0.22
            let bgBri = isDarkMode
                ? brightness * 0.18        // e.g. bri=1.0 → 0.18
                : 0.80 + brightness * 0.18 // e.g. bri=1.0 → 0.98
            let bgOpacity: Double = isDarkMode ? 0.72 : 0.60
            return Color(hue: hue, saturation: bgSat, brightness: bgBri)
                   .opacity(bgOpacity)
        }
        return isDarkMode ? .black.opacity(0.40) : .white.opacity(0.08)
    }

    // MARK: - Derived: cell borders

    /// Stroke colour for ExpandableGlassRow borders.
    /// Hi-contrast → standard grey/separator (adapts to light/dark automatically).
    /// Lo-contrast → soft tint derived from the primary hue.
    var cellBorderColor: Color {
        isHiContrast
            ? Color(nsColor: .separatorColor).opacity(0.30)
            : Color(hue: hue, saturation: saturation * 0.65, brightness: min(1.0, brightness * 0.90)).opacity(0.28)
    }

    var cellBorderHoverColor: Color {
        isHiContrast
            ? Color(nsColor: .separatorColor).opacity(0.50)
            : Color(hue: hue, saturation: saturation * 0.75, brightness: min(1.0, brightness * 0.95)).opacity(0.45)
    }

    // MARK: - Derived: colorScheme

    var colorScheme: ColorScheme { isDarkMode ? .dark : .light }

    // MARK: - Persistence

    private func save() {
        let d = UserDefaults.standard
        d.set(hue,          forKey: "theme.hue")
        d.set(saturation,   forKey: "theme.sat")
        d.set(brightness,   forKey: "theme.bri")
        d.set(isDarkMode,   forKey: "theme.dark")
        d.set(isHiContrast, forKey: "theme.hiContrast")
    }
}
