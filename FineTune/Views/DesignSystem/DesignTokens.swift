// FineTune/Views/DesignSystem/DesignTokens.swift
import SwiftUI

/// Design System tokens for FineTune UI
/// Centralized values for colors, typography, spacing, dimensions, and animations
enum DesignTokens {

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

        /// Popup background overlay
        static let popupOverlay: Color = .black.opacity(0.4)

        /// Recessed panel background (EQ panel)
        static let recessedBackground: Color = .black.opacity(0.3)

        // MARK: Menu/Picker

        /// Menu button background
        static let menuBackground: Color = .clear

        /// Menu button border
        static let menuBorder: Color = .white.opacity(0.12)

        /// Menu button border on hover
        static let menuBorderHover: Color = .white.opacity(0.25)

        /// Picker background
        static let pickerBackground: Color = .primary.opacity(0.08)

        /// Picker hover
        static let pickerHover: Color = .primary.opacity(0.12)

        // MARK: VU Meter (Professional audio standard - NOT themed)

        /// VU meter green segments (bars 0-3, safe levels)
        static let vuGreen = Color(red: 0.20, green: 0.78, blue: 0.40)

        /// VU meter yellow segments (bars 4-5, caution)
        static let vuYellow = Color(red: 0.95, green: 0.75, blue: 0.20)

        /// VU meter orange segment (bar 6, warning)
        static let vuOrange = Color(red: 0.95, green: 0.50, blue: 0.20)

        /// VU meter red segment (bar 7, peak/clip)
        static let vuRed = Color(red: 0.90, green: 0.25, blue: 0.25)

        /// VU meter unlit bar color
        static let vuUnlit: Color = .primary.opacity(0.08)

        /// VU meter muted state
        static let vuMuted: Color = .primary.opacity(0.35)

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
        static let popupWidth: CGFloat = 580

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

        /// VU meter width
        static let vuMeterWidth: CGFloat = 28

        /// Controls section width
        static var controlsWidth: CGFloat {
            contentWidth - iconSize - Spacing.sm - 100
        }

        /// Percentage text width (fixed to prevent layout shift)
        static let percentageWidth: CGFloat = 40

        // MARK: VU Meter

        /// VU meter bar height
        static let vuMeterBarHeight: CGFloat = 10

        /// VU meter bar spacing
        static let vuMeterBarSpacing: CGFloat = 2

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
}
