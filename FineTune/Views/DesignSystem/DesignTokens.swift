// FineTune/Views/DesignSystem/DesignTokens.swift
import SwiftUI
import AppKit

/// Design System tokens for FineTune UI
/// Centralized values for colors, typography, spacing, dimensions, and animations
enum DesignTokens {

    // MARK: - Internal helpers

    /// Builds a SwiftUI Color that resolves to `light` or `dark` based on the
    /// effective NSAppearance at draw time. SwiftUI re-resolves automatically
    /// when the appearance changes (system toggle or override change) because
    /// `Color(nsColor:)` preserves the underlying NSColor's adaptability.
    ///
    /// `name` is NSColor's caching key. Pass a unique name per token; two
    /// dynamic colors sharing a name silently resolve to the same instance.
    /// `DesignTokensDynamicResolutionTests` enforces uniqueness by asserting
    /// per-token RGBA values.
    static func dynamicColor(name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Colors

    enum Colors {
        // MARK: Text (Vibrancy-aware)

        /// Primary text - automatically adapts for vibrancy on materials
        static let textPrimary: Color = .primary

        /// Secondary text - slightly muted, still vibrant
        static let textSecondary: Color = .secondary

        /// Tertiary text - for less important content
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        /// Quaternary text - very subtle
        static let textQuaternary = Color(nsColor: .quaternaryLabelColor)

        // MARK: Interactive

        /// Default interactive element color
        static let interactiveDefault: Color = .primary.opacity(0.7)

        /// Hovered interactive element color
        static let interactiveHover: Color = .primary.opacity(0.9)

        /// Active/pressed interactive element color
        static let interactiveActive: Color = .primary

        /// System accent color for selections and primary actions
        static let accentPrimary: Color = .accentColor

        /// Mute button active (muted state) - red for visibility
        static let mutedIndicator = Color(nsColor: .systemRed).opacity(0.85)

        /// Default device indicator - uses accent color
        static let defaultDevice: Color = .accentColor

        // MARK: Separators & Borders

        /// System separator color - adapts to appearance
        static let separator = Color(nsColor: .separatorColor)

        /// Subtle border for glass elements
        static let glassBorder = Color(nsColor: .separatorColor).opacity(0.3)

        /// Hover-state border
        static let glassBorderHover = Color(nsColor: .separatorColor).opacity(0.5)

        // MARK: Slider

        /// Slider track background (unfilled) - visible on glass
        static let sliderTrack: Color = .primary.opacity(0.15)

        /// Slider filled track - uses accent color
        static let sliderFill: Color = .accentColor

        /// Slider thumb
        static let sliderThumb: Color = .white

        /// Unity marker on slider
        static let unityMarker: Color = .primary.opacity(0.5)

        // MARK: Control Elements

        /// EQ/slider thumb background
        static let thumbBackground: Color = .white

        /// EQ/slider thumb center dot
        static let thumbDot: Color = .black.opacity(0.7)

        // MARK: Glass Effects

        /// Popup background overlay. Sits over NSVisualEffectView's `.popover`
        /// material. Light bumped from 0.10 → 0.50 so the popup reads as
        /// crisp white-tilted glass over arbitrary wallpapers (Control Center
        /// sweet spot) instead of muddy gray. The earlier 0.55 wash killed
        /// vibrancy entirely; 0.50 keeps a hint of desktop tint.
        static let popupOverlay = dynamicColor(
            name: "popupOverlay",
            light: NSColor.white.withAlphaComponent(0.50),
            dark: NSColor.black.withAlphaComponent(0.4)
        )

        /// Recessed panel background (EQ panel). Light mode is nearly flush
        /// with the surrounding glass; opaque cards do the floating instead.
        static let recessedBackground = dynamicColor(
            name: "recessedBackground",
            light: NSColor.black.withAlphaComponent(0.04),
            dark: NSColor.black.withAlphaComponent(0.3)
        )

        // MARK: Menu/Picker

        /// Menu button background
        static let menuBackground: Color = .clear

        /// Menu button border. Light bumped for visible edge on glass surface.
        static let menuBorder = dynamicColor(
            name: "menuBorder",
            light: NSColor.black.withAlphaComponent(0.18),
            dark: NSColor.white.withAlphaComponent(0.12)
        )

        /// Menu button border on hover. Strong contrast in light mode so the
        /// hover state reads at a glance.
        static let menuBorderHover = dynamicColor(
            name: "menuBorderHover",
            light: NSColor.black.withAlphaComponent(0.32),
            dark: NSColor.white.withAlphaComponent(0.25)
        )

        /// Picker background
        static let pickerBackground: Color = .primary.opacity(0.08)

        /// Picker hover
        static let pickerHover: Color = .primary.opacity(0.12)

        // MARK: Hover & Glass Surface

        /// Hover background for tappable rows. With flat-row design (no
        /// resting fill or border), this is the primary "this row is active"
        /// affordance, so it needs to read clearly without being heavy.
        /// Light bumped from 0.08 → 0.115 to remain unambiguous on the
        /// new whiter glass without competing with the selected-row
        /// indicator. Matches the macOS-native System Settings pattern.
        static let hoverSurface = dynamicColor(
            name: "hoverSurface",
            light: NSColor.black.withAlphaComponent(0.115),
            dark: NSColor.white.withAlphaComponent(0.07)
        )

        /// Default row fill. Transparent — rows blend with the popup
        /// material at rest, like System Settings / Notification Center.
        /// Hover reveals `hoverSurface` as the meaningful interaction signal.
        static let glassFill = dynamicColor(
            name: "glassFill",
            light: NSColor.clear,
            dark: NSColor.clear
        )

        /// Stronger glass-card fill for emphasised badges and sheet inserts
        /// (DEFAULT pill, AutoEQ search panel, device-detail sheet). Not used
        /// for default row backgrounds.
        static let glassFillStrong = dynamicColor(
            name: "glassFillStrong",
            light: NSColor.white.withAlphaComponent(0.85),
            dark: NSColor.white.withAlphaComponent(0.1)
        )

        /// Default row border. Transparent — flat rows have no resting edge.
        static let glassRowBorder = dynamicColor(
            name: "glassRowBorder",
            light: NSColor.clear,
            dark: NSColor.clear
        )

        /// Hovered row edge — soft hairline visible only when the row is
        /// being interacted with. Pairs with `hoverSurface` to define the
        /// active row.
        static let glassRowBorderHover = dynamicColor(
            name: "glassRowBorderHover",
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.15)
        )

        /// HUD panel hairline border (Tahoe + Classic).
        static let hudBorder = dynamicColor(
            name: "hudBorder",
            light: NSColor.black.withAlphaComponent(0.15),
            dark: NSColor.white.withAlphaComponent(0.08)
        )

        // MARK: Cards & Badges

        /// Lifted-card fill used by the EQ panel and Settings sections.
        /// Light reads as a white card on the popup glass; dark reads as
        /// a subtle translucent surface on the dark glass. Pairs with
        /// `eqCardBorder` for the hairline edge.
        static let eqCardBackground = dynamicColor(
            name: "eqCardBackground",
            light: NSColor.white.withAlphaComponent(0.78),
            dark: NSColor.white.withAlphaComponent(0.07)
        )

        /// Hairline border for the lifted card. Visible enough to define
        /// the edge, quiet enough to read as part of the glass family.
        static let eqCardBorder = dynamicColor(
            name: "eqCardBorder",
            light: NSColor.black.withAlphaComponent(0.06),
            dark: NSColor.white.withAlphaComponent(0.10)
        )

        /// Settings cards use the same family as the EQ card. Aliased for
        /// call-site clarity; if values diverge later, split into a
        /// separate dynamic color.
        static let settingsCardBackground: Color = eqCardBackground

        /// Settings card border. Same family as `eqCardBorder`.
        static let settingsCardBorder: Color = eqCardBorder

        /// Monochrome circular badge fill used on non-selected device rows.
        /// The selected state uses a `Color.accentColor` gradient inline in
        /// `DeviceBadge`; that does not need a token.
        static let deviceBadgeMonoFill = dynamicColor(
            name: "deviceBadgeMonoFill",
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.10)
        )

        /// Foreground color for the device-badge SF symbol on a non-selected
        /// row. Selected rows use white directly inside `DeviceBadge`.
        static let deviceBadgeMonoForeground = dynamicColor(
            name: "deviceBadgeMonoForeground",
            light: NSColor.black.withAlphaComponent(0.65),
            dark: NSColor.white.withAlphaComponent(0.70)
        )

        /// Section-header text ("APPS", "GENERAL", etc.). The system
        /// `tertiaryLabelColor` is too faint as a section divider in light
        /// mode; this token gives the headers Apple-app-style readability
        /// without changing the dark appearance. Light bumped from 0.55
        /// → 0.65 so headers anchor each section on the whiter glass
        /// without changing tracking or weight.
        static let sectionHeaderText = dynamicColor(
            name: "sectionHeaderText",
            light: NSColor.black.withAlphaComponent(0.65),
            dark: NSColor.white.withAlphaComponent(0.40)
        )

        // MARK: VU Meter (Professional audio standard - NOT themed)

        /// VU meter green segments (bars 0-3, safe levels)
        static let vuGreen = Color(red: 0.20, green: 0.78, blue: 0.40)

        /// VU meter yellow segments (bars 4-5, caution)
        static let vuYellow = Color(red: 0.95, green: 0.75, blue: 0.20)

        /// VU meter orange segment (bar 6, warning)
        static let vuOrange = Color(red: 0.95, green: 0.50, blue: 0.20)

        /// VU meter red segment (bar 7, peak/clip)
        static let vuRed = Color(red: 0.90, green: 0.25, blue: 0.25)

        /// VU meter unlit bar color (matches sliderTrack for visual consistency)
        static let vuUnlit: Color = .primary.opacity(0.15)

        /// VU meter muted state
        static let vuMuted: Color = .primary.opacity(0.35)

        // MARK: AutoEQ

        /// AutoEQ empty-state dashed border. Light bumped so the dashed
        /// outline reads on a translucent panel.
        static let autoEQEmptyBorder = dynamicColor(
            name: "autoEQEmptyBorder",
            light: NSColor.black.withAlphaComponent(0.22),
            dark: NSColor.white.withAlphaComponent(0.1)
        )

        /// AutoEQ empty-state icon color. Light made darker so the icon is
        /// visible on a near-white background.
        static let autoEQEmptyIcon = dynamicColor(
            name: "autoEQEmptyIcon",
            light: NSColor(white: 0.45, alpha: 1.0),
            dark: NSColor(white: 0.267, alpha: 1.0)
        )

        /// AutoEQ toggle label text color (Correction / Preamp labels).
        static let autoEQToggleLabel = dynamicColor(
            name: "autoEQToggleLabel",
            light: NSColor.black.withAlphaComponent(0.65),
            dark: NSColor.white.withAlphaComponent(0.5)
        )

        // MARK: HUD

        /// Active dot in Tahoe HUD tick track
        static let hudDotActive: Color = .primary.opacity(0.85)

        /// Inactive dot in Tahoe HUD tick track
        static let hudDotInactive: Color = .primary.opacity(0.18)

        /// Active tile in Classic HUD segment row
        static let hudTileActive: Color = .primary.opacity(0.7)

        /// Inactive tile in Classic HUD segment row
        static let hudTileInactive: Color = .primary.opacity(0.2)
    }

    // MARK: - Typography

    enum Typography {
        /// Section header text (e.g., "OUTPUT DEVICES") - prominent and bold
        static let sectionHeader = Font.system(size: 12, weight: .bold)

        /// Section header letter spacing (tighter at larger size)
        static let sectionHeaderTracking: CGFloat = 1.2

        /// App/device name in rows
        static let rowName = Font.system(size: 13, weight: .regular)

        /// Bold variant for default device name
        static let rowNameBold = Font.system(size: 13, weight: .semibold)

        /// Volume percentage display
        static let percentage = Font.system(size: 11, weight: .medium, design: .monospaced)

        /// Small caption text
        static let caption = Font.system(size: 10, weight: .regular)

        /// Device picker text
        static let pickerText = Font.system(size: 11, weight: .regular)

        /// EQ frequency labels
        static let eqLabel = Font.system(size: 9, weight: .medium, design: .monospaced)

        /// AutoEQ card profile name
        static let cardProfileName = Font.system(size: 12, weight: .semibold)

        /// AutoEQ card source/measuredBy
        static let cardSource = Font.system(size: 9, weight: .regular)

        /// Settings card header (sentence case, 13pt semibold)
        static let cardHeader = Font.system(size: 13, weight: .semibold)

        /// Settings row description (11pt regular, tertiary)
        static let rowDescription = Font.system(size: 11, weight: .regular)
    }

    // MARK: - Spacing (standard 1× multiplier)

    enum Spacing {
        /// 2pt - Extra extra small
        static let xxs: CGFloat = 2

        /// 4pt - Extra small
        static let xs: CGFloat = 4

        /// 8pt - Small
        static let sm: CGFloat = 8

        /// 12pt - Medium
        static let md: CGFloat = 12

        /// 16pt - Large
        static let lg: CGFloat = 16

        /// 20pt - Extra large
        static let xl: CGFloat = 20

        /// 24pt - Extra extra large
        static let xxl: CGFloat = 24
    }

    // MARK: - Dimensions

    enum Dimensions {
        // MARK: Base Configuration

        /// Main popup width
        static let popupWidth: CGFloat = 510

        /// Content padding
        static var contentPadding: CGFloat { Spacing.lg }

        /// Available content width after padding
        static var contentWidth: CGFloat {
            popupWidth - (contentPadding * 2)
        }

        // MARK: Fixed Dimensions

        /// Max height for scrollable content
        static let maxScrollHeight: CGFloat = 400

        // MARK: Corner Radii (rounded style - 10pt)

        /// Corner radius for popup
        static let cornerRadius: CGFloat = 12

        /// Corner radius for row cards (glass bars)
        static let rowRadius: CGFloat = 10

        /// Corner radius for buttons/pickers
        static let buttonRadius: CGFloat = 6

        /// App/device icon size
        static let iconSize: CGFloat = 22

        /// Small icon size
        static let iconSizeSmall: CGFloat = 14

        // MARK: Slider Dimensions (minimal style)

        /// Slider track height
        static let sliderTrackHeight: CGFloat = 3

        /// Slider thumb width (pill shape)
        static let sliderThumbWidth: CGFloat = 16

        /// Slider thumb height (pill shape)
        static let sliderThumbHeight: CGFloat = 10

        /// Circular thumb size
        static let sliderThumbSize: CGFloat = 12

        /// Minimum touch target
        static let minTouchTarget: CGFloat = 16

        /// Row content height
        static let rowContentHeight: CGFloat = 28

        // MARK: Component Widths

        /// Slider width
        static let sliderWidth: CGFloat = 140

        /// Minimum slider width
        static let sliderMinWidth: CGFloat = 120

        /// Percentage text width (fixed to prevent layout shift)
        static let percentageWidth: CGFloat = 40

        // MARK: VU Meter

        /// VU meter bar count
        static let vuMeterBarCount: Int = 8

        // MARK: Settings Row

        /// Settings row icon column width
        static let settingsIconWidth: CGFloat = 24

        /// Settings slider width
        static let settingsSliderWidth: CGFloat = 200

        /// Settings percentage text width
        static let settingsPercentageWidth: CGFloat = 44

        /// Settings picker width
        static let settingsPickerWidth: CGFloat = 120

    }

    // MARK: - Animation (smooth style - macOS-like springs)

    enum Animation {
        /// Quick spring for small elements
        static let quick = SwiftUI.Animation.spring(response: 0.2, dampingFraction: 0.85)

        /// Hover transition (brief and precise per HIG)
        static let hover = SwiftUI.Animation.easeOut(duration: 0.12)

        /// VU meter level change
        static let vuMeterLevel = SwiftUI.Animation.linear(duration: 0.05)
    }

    // MARK: - Timing

    enum Timing {
        /// VU meter update interval (30fps)
        static let vuMeterUpdateInterval: TimeInterval = 1.0 / 30.0

        /// VU meter peak hold duration
        static let vuMeterPeakHold: TimeInterval = 0.5
    }

    // MARK: - Links

    enum Links {
        /// Financial support page (currently Ko-fi, URL is platform-agnostic in UI)
        static let support = URL(string: "https://ko-fi.com/ronitsingh10")!

        /// Project license on GitHub
        static let license = URL(string: "https://github.com/ronitsingh10/FineTune/blob/main/LICENSE")!
    }
}
