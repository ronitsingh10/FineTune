// FineTune/Views/DesignSystem/ThemeManager.swift
import SwiftUI
import AppKit
import Observation

// MARK: - ThemeMode

/// The three visual appearance modes available in the FX tab theme selector.
enum ThemeMode: String {
    case dark  = "dark"
    case light = "light"
    /// Liquid Glass — iOS 26-inspired ultra-transparent frosted glass aesthetic.
    case glass = "glass"
}

/// App-wide theme. Inject at the root with .environment(themeManager)
/// and read in child views with @Environment(ThemeManager.self).
///
/// - primaryColor / accentColor: the user-chosen hue used for sliders, fills, dots
/// - isDarkMode:    dark or light background
/// - isGlassMode:   iOS 26 liquid glass aesthetic (overrides isDarkMode, uses dark scheme)
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

    /// Liquid Glass mode — iOS 26-inspired ultra-clear frosted glass aesthetic.
    /// When active, the app uses a dark color scheme with maximum-transparency
    /// NSVisualEffectView material, iridescent prismatic overlays, and specular
    /// white borders, independently of isDarkMode.
    var isGlassMode: Bool = false  { didSet { save() } }

    // Optional independent cell-background colour override.
    // When useCustomCellBg = false, backgroundOverlayColor derives from primary as before.
    var useCustomCellBg: Bool   = false { didSet { save() } }
    var cellBgHue:       Double = 0.583 { didSet { save() } }
    var cellBgSat:       Double = 0.80  { didSet { save() } }
    var cellBgBri:       Double = 1.00  { didSet { save() } }

    // Optional independent accent override.
    var useCustomAccent: Bool   = false { didSet { save() } }
    var accentHue:       Double = 0.583 { didSet { save() } }
    var accentSat:       Double = 0.80  { didSet { save() } }
    var accentBri:       Double = 1.00  { didSet { save() } }

    // Optional independent background overlay override.
    var useCustomBackground: Bool   = false { didSet { save() } }
    var backgroundHue:       Double = 0.583 { didSet { save() } }
    var backgroundSat:       Double = 0.80  { didSet { save() } }
    var backgroundBri:       Double = 1.00  { didSet { save() } }

    // Optional independent cell-border override.
    var useCustomCellBorder: Bool   = false { didSet { save() } }
    var cellBorderHue:       Double = 0.583 { didSet { save() } }
    var cellBorderSat:       Double = 0.80  { didSet { save() } }
    var cellBorderBri:       Double = 1.00  { didSet { save() } }

    // Suppresses save() during init so intermediate assignments don't overwrite
    // not-yet-loaded UserDefaults values with Swift property defaults.
    private var isLoading = true

    /// Incremented on every meaningful theme change. Views that read derived Color
    /// properties (which @Observable cannot track directly) should also read this
    /// property to ensure they re-render when the theme changes.
    private(set) var themeVersion: Int = 0

    /// KVO token that watches NSApp.effectiveAppearance.
    /// Used in glass mode so `colorScheme` tracks the system dark/light preference
    /// — critical when macOS "Reduce Transparency" is on and NSVisualEffectView
    /// falls back to an opaque fill that must match the real system appearance.
    @ObservationIgnored
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Init (loads from UserDefaults)

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "theme.hue")        != nil { hue          = d.double(forKey: "theme.hue") }
        if d.object(forKey: "theme.sat")        != nil { saturation   = d.double(forKey: "theme.sat") }
        if d.object(forKey: "theme.bri")        != nil { brightness   = d.double(forKey: "theme.bri") }
        if d.object(forKey: "theme.dark")       != nil { isDarkMode   = d.bool(forKey: "theme.dark") }
        if d.object(forKey: "theme.hiContrast") != nil { isHiContrast = d.bool(forKey: "theme.hiContrast") }
        if d.object(forKey: "theme.glass")      != nil { isGlassMode  = d.bool(forKey: "theme.glass") }
        if d.object(forKey: "theme.cellBgOn")   != nil { useCustomCellBg = d.bool(forKey: "theme.cellBgOn") }
        if d.object(forKey: "theme.cellBgHue")  != nil { cellBgHue   = d.double(forKey: "theme.cellBgHue") }
        if d.object(forKey: "theme.cellBgSat")  != nil { cellBgSat   = d.double(forKey: "theme.cellBgSat") }
        if d.object(forKey: "theme.cellBgBri")  != nil { cellBgBri   = d.double(forKey: "theme.cellBgBri") }

        // Default overrides to primary unless stored in defaults.
        accentHue = hue; accentSat = saturation; accentBri = brightness
        backgroundHue = hue; backgroundSat = saturation; backgroundBri = brightness
        cellBorderHue = hue; cellBorderSat = saturation; cellBorderBri = brightness

        if d.object(forKey: "theme.accentOn")     != nil { useCustomAccent = d.bool(forKey: "theme.accentOn") }
        if d.object(forKey: "theme.accentHue")    != nil { accentHue = d.double(forKey: "theme.accentHue") }
        if d.object(forKey: "theme.accentSat")    != nil { accentSat = d.double(forKey: "theme.accentSat") }
        if d.object(forKey: "theme.accentBri")    != nil { accentBri = d.double(forKey: "theme.accentBri") }

        if d.object(forKey: "theme.bgOn")         != nil { useCustomBackground = d.bool(forKey: "theme.bgOn") }
        if d.object(forKey: "theme.bgHue")        != nil { backgroundHue = d.double(forKey: "theme.bgHue") }
        if d.object(forKey: "theme.bgSat")        != nil { backgroundSat = d.double(forKey: "theme.bgSat") }
        if d.object(forKey: "theme.bgBri")        != nil { backgroundBri = d.double(forKey: "theme.bgBri") }

        if d.object(forKey: "theme.borderOn")     != nil { useCustomCellBorder = d.bool(forKey: "theme.borderOn") }
        if d.object(forKey: "theme.borderHue")    != nil { cellBorderHue = d.double(forKey: "theme.borderHue") }
        if d.object(forKey: "theme.borderSat")    != nil { cellBorderSat = d.double(forKey: "theme.borderSat") }
        if d.object(forKey: "theme.borderBri")    != nil { cellBorderBri = d.double(forKey: "theme.borderBri") }
        isLoading = false

        // Defer KVO setup one run-loop tick so NSApp is fully initialised before
        // we observe it. (@State properties are created before NSApplication launches,
        // so NSApp is still nil at the point init() returns.)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isGlassMode else { return }
                    // Bump themeVersion so @Observable-tracked views re-evaluate colorScheme.
                    self.themeVersion &+= 1
                }
            }
        }
    }

    // MARK: - Derived: accent

    /// Raw primary colour chosen by the user (full saturation).
    var primaryColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Accent used for interactive elements (slider fills, dots, active states).
    /// Hi-contrast → vivid.  Lo-contrast → desaturated/pastel.
    var accentColor: Color {
        if useCustomAccent {
            return Color(hue: accentHue, saturation: accentSat, brightness: accentBri)
        }
        return isHiContrast
            ? primaryColor
            : Color(hue: hue, saturation: saturation * 0.45,
                    brightness: min(1.0, brightness * 1.08))
    }

    // MARK: - Derived: background

    /// Overlay tint applied over the blur material for the popup background.
    ///
    /// Glass mode        → near-zero tint; NSVisualEffectView provides all depth
    /// Hi-contrast dark  → black 40% (original behaviour)
    /// Hi-contrast light → white 8%
    /// Lo-contrast       → pastel tint derived from the user's hue/sat/bri
    /// The effective hue/sat/bri for the background overlay.
    /// Window-level background overlay — always derived from primary colour, never from
    /// cellBg values. cellTintColor is the per-cell overlay that uses cellBg values.
    var backgroundOverlayColor: Color {
        // Glass: minimal tint — the ultra-thin visual effect material handles depth
        if isGlassMode {
            return primaryColor.opacity(0.04)
        }
        if useCustomBackground {
            let op: Double
            if isHiContrast { op = isDarkMode ? 0.40 : 0.08 }
            else { op = isDarkMode ? 0.72 : 0.60 }
            return Color(hue: backgroundHue, saturation: backgroundSat, brightness: backgroundBri).opacity(op)
        }
        guard isHiContrast else {
            let bgSat = isDarkMode ? saturation * 0.55 : saturation * 0.28
            let bgBri = isDarkMode ? brightness * 0.18 : 0.80 + brightness * 0.18
            let bgOpacity: Double = isDarkMode ? 0.72 : 0.60
            return Color(hue: hue, saturation: bgSat, brightness: bgBri).opacity(bgOpacity)
        }
        return isDarkMode ? .black.opacity(0.40) : .white.opacity(0.08)
    }

    // MARK: - Derived: separator accent
    /// Used for element-break dividers and active tab backgrounds.
    /// Hi-contrast → neutral grey (matches system separator tone).
    /// Lo-contrast → primary hue at low-medium opacity so it's visibly tinted but subtle.
    var separatorAccentColor: Color {
        if isHiContrast {
            return isDarkMode
                ? Color.white.opacity(0.22)
                : Color.black.opacity(0.18)
        } else {
            let base = useCustomAccent
                ? Color(hue: accentHue, saturation: accentSat, brightness: accentBri)
                : accentColor
            return base.opacity(0.35)
        }
    }

    /// Section header text (e.g. "APPS") — stronger than separator lines for readability.
    var sectionHeaderColor: Color {
        if isHiContrast {
            return separatorAccentColor
        } else {
            let base = useCustomAccent
                ? Color(hue: accentHue, saturation: accentSat, brightness: accentBri)
                : accentColor
            return base.opacity(0.55)
        }
    }

    // MARK: - Derived: cell tint (what cells actually render on top of their material)
    /// The tint overlay applied inside each ExpandableGlassRow.
    /// When useCustomCellBg=true, derives from cellBg* values; otherwise from primary.
    /// This is the ONLY place that uses cellBg* — backgroundOverlayColor uses primary only.
    var cellTintColor: Color {
        // Glass mode: extremely subtle accent wash — cells should feel nearly transparent
        if isGlassMode {
            return Color(hue: hue, saturation: saturation * 0.25, brightness: 0.95).opacity(0.05)
        }
        if useCustomCellBg {
            // Explicit cell bg — use stored HSB directly at fixed opacity.
            let opacity: Double = isDarkMode ? 0.30 : 0.40
            return Color(hue: cellBgHue, saturation: cellBgSat, brightness: cellBgBri)
                        .opacity(opacity)
        } else {
            // No override — derive subtle tint from primary.
            let bgSat = isDarkMode ? saturation * 0.55 : saturation * 0.28
            let bgBri = isDarkMode ? brightness * 0.18 : 0.80 + brightness * 0.18
            let opacity: Double = isDarkMode ? 0.18 : 0.28
            return Color(hue: hue, saturation: bgSat, brightness: bgBri).opacity(opacity)
        }
    }

    // MARK: - Derived: cell borders

    /// Stroke colour for ExpandableGlassRow borders.
    /// Glass mode  → bright specular white — the "edge-of-glass" highlight.
    /// Hi-contrast → standard grey/separator (adapts to light/dark automatically).
    /// Lo-contrast → soft tint derived from the primary hue.
    var cellBorderColor: Color {
        if isGlassMode {
            return Color.white.opacity(0.22)
        }
        if useCustomCellBorder {
            let base = Color(hue: cellBorderHue, saturation: cellBorderSat, brightness: cellBorderBri)
            let opacity = isHiContrast ? 0.30 : 0.28
            return base.opacity(opacity)
        }
        return isHiContrast
            ? Color(nsColor: .separatorColor).opacity(0.30)
            : Color(hue: hue, saturation: saturation * 0.65, brightness: min(1.0, brightness * 0.90)).opacity(0.28)
    }

    var cellBorderHoverColor: Color {
        if isGlassMode {
            return Color.white.opacity(0.40)
        }
        if useCustomCellBorder {
            let base = Color(hue: cellBorderHue, saturation: cellBorderSat, brightness: cellBorderBri)
            let opacity = isHiContrast ? 0.50 : 0.45
            return base.opacity(opacity)
        }
        return isHiContrast
            ? Color(nsColor: .separatorColor).opacity(0.50)
            : Color(hue: hue, saturation: saturation * 0.75, brightness: min(1.0, brightness * 0.95)).opacity(0.45)
    }

    // MARK: - Derived: colorScheme

    /// In glass mode, tracks `NSApp.effectiveAppearance` (the real system dark/light)
    /// rather than the stored `isDarkMode` flag. This is essential when macOS
    /// "Reduce Transparency" is active: NSVisualEffectView falls back to an opaque
    /// solid fill, so the colour scheme must match what the system is actually showing.
    /// In dark/light modes, the stored `isDarkMode` flag is used as normal.
    var colorScheme: ColorScheme {
        if isGlassMode {
            // NSApp may be nil during the very first render (before the deferred KVO
            // setup fires), so fall back to isDarkMode in that narrow window.
            let isDark = NSApp?.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? .dark : .light
        }
        return isDarkMode ? .dark : .light
    }

    // MARK: - Persistence

    private func save() {
        guard !isLoading else { return }
        themeVersion &+= 1   // overflow-safe bump; triggers @Observable re-render
        let d = UserDefaults.standard
        d.set(hue,             forKey: "theme.hue")
        d.set(saturation,      forKey: "theme.sat")
        d.set(brightness,      forKey: "theme.bri")
        d.set(isDarkMode,      forKey: "theme.dark")
        d.set(isHiContrast,    forKey: "theme.hiContrast")
        d.set(isGlassMode,     forKey: "theme.glass")
        d.set(useCustomCellBg, forKey: "theme.cellBgOn")
        d.set(cellBgHue,       forKey: "theme.cellBgHue")
        d.set(cellBgSat,       forKey: "theme.cellBgSat")
        d.set(cellBgBri,       forKey: "theme.cellBgBri")

        d.set(useCustomAccent, forKey: "theme.accentOn")
        d.set(accentHue,       forKey: "theme.accentHue")
        d.set(accentSat,       forKey: "theme.accentSat")
        d.set(accentBri,       forKey: "theme.accentBri")

        d.set(useCustomBackground, forKey: "theme.bgOn")
        d.set(backgroundHue,       forKey: "theme.bgHue")
        d.set(backgroundSat,       forKey: "theme.bgSat")
        d.set(backgroundBri,       forKey: "theme.bgBri")

        d.set(useCustomCellBorder, forKey: "theme.borderOn")
        d.set(cellBorderHue,       forKey: "theme.borderHue")
        d.set(cellBorderSat,       forKey: "theme.borderSat")
        d.set(cellBorderBri,       forKey: "theme.borderBri")
    }
}
