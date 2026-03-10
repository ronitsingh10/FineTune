// FineTune/Views/DesignSystem/ViewModifiers.swift
import SwiftUI

// MARK: - Hoverable Row Modifier (solid colors for reliable rendering)

struct HoverableRowModifier: ViewModifier {
    @State private var isHovered = false
    @Environment(ThemeManager.self) private var theme

    func body(content: Content) -> some View {
        let _ = theme.themeVersion
        return content
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(.ultraThinMaterial)
            )
            // Cell tint overlay — same as ExpandableGlassRow
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(theme.cellTintColor)
                    .allowsHitTesting(false)
            }
            // Hover effect overlay
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(isHovered ? Color.white.opacity(0.04) : Color.clear)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .stroke(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}

// MARK: - Section Header Style Modifier

struct SectionHeaderStyleModifier: ViewModifier {
    @Environment(ThemeManager.self) private var theme
    func body(content: Content) -> some View {
        let _ = theme.themeVersion
        // Use colorScheme (not isDarkMode directly) so glass mode's system-tracking
        // appearance is reflected — isDarkMode stays true in glass mode but colorScheme
        // may return .light when the system has switched to Light.
        let isDark = theme.colorScheme == .dark
        let darkShadow  = isDark ? Color.black.opacity(0.45) : Color.white.opacity(0.80)
        let lightShadow = isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.28)
        return content
            .font(DesignTokens.Typography.sectionHeader)
            .foregroundStyle(theme.sectionHeaderColor)
            .tracking(DesignTokens.Typography.sectionHeaderTracking)
            .textCase(.uppercase)
            .shadow(color: darkShadow, radius: 1.2, x: 0, y: 1)
            .shadow(color: lightShadow, radius: 0.2, x: 0, y: -0.6)
    }
}

// MARK: - Percentage Text Style Modifier

struct PercentageTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DesignTokens.Typography.percentage)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
    }
}

// MARK: - Icon Button Style Modifier (Vibrancy-aware)

struct IconButtonStyleModifier: ViewModifier {
    let isActive: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foregroundColor)
            .symbolRenderingMode(.hierarchical)  // Better vibrancy support
            .frame(minWidth: DesignTokens.Dimensions.minTouchTarget,
                   minHeight: DesignTokens.Dimensions.minTouchTarget)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
    }

    private var foregroundColor: Color {
        if isActive {
            return DesignTokens.Colors.mutedIndicator
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }
}

// MARK: - Glass Button Style Modifier

/// Button styling for glass aesthetic with vibrancy
struct GlassButtonStyleModifier: ViewModifier {
    @State private var isHovered = false
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
                        lineWidth: 0.5
                    )
            }
            .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.02 : 1.0))
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.quick, value: isPressed)
    }
}

// MARK: - Vibrancy Icon Modifier

/// Applies proper vibrancy styling to SF Symbols
struct VibrancyIconModifier: ViewModifier {
    let style: VibrancyStyle

    enum VibrancyStyle {
        case primary   // Full brightness
        case secondary // Slightly muted
        case tertiary  // More muted
    }

    func body(content: Content) -> some View {
        content
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(foregroundColor)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .tertiary:
            return DesignTokens.Colors.textTertiary
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies hoverable row styling (forwards to floatingGlassRow)
    func hoverableRow() -> some View {
        modifier(HoverableRowModifier())
    }

    /// Applies section header text styling (uppercase, spaced, tertiary color)
    func sectionHeaderStyle() -> some View {
        modifier(SectionHeaderStyleModifier())
    }

    /// Applies percentage display styling (monospace, secondary, fixed width)
    func percentageStyle() -> some View {
        modifier(PercentageTextModifier())
    }

    /// Applies icon button styling with hover state (vibrancy-aware)
    func iconButtonStyle(isActive: Bool = false) -> some View {
        modifier(IconButtonStyleModifier(isActive: isActive))
    }

    /// Applies glass button styling
    func glassButtonStyle() -> some View {
        modifier(GlassButtonStyleModifier())
    }

    /// Applies vibrancy styling to SF Symbol icons
    func vibrancyIcon(_ style: VibrancyIconModifier.VibrancyStyle = .secondary) -> some View {
        modifier(VibrancyIconModifier(style: style))
    }
}

// MARK: - Previews

#Preview("Floating Glass Row") {
    VStack(spacing: 8) {
        HStack {
            Image(systemName: "music.note")
                .vibrancyIcon()
            Text("Spotify")
            Spacer()
            Text("75%")
                .percentageStyle()
        }
        .hoverableRow()

        HStack {
            Image(systemName: "video")
                .vibrancyIcon()
            Text("Zoom")
            Spacer()
            Text("100%")
                .percentageStyle()
        }
        .hoverableRow()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Section Header") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Output Devices")
            .sectionHeaderStyle()

        Text("Apps")
            .sectionHeaderStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Percentage Text") {
    HStack {
        Text("100%").percentageStyle()
        Text("75%").percentageStyle()
        Text("0%").percentageStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Icon Button Styles") {
    HStack(spacing: 16) {
        Button { } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .iconButtonStyle(isActive: false)

        Button { } label: {
            Image(systemName: "speaker.slash.fill")
        }
        .iconButtonStyle(isActive: true)

        Button { } label: {
            Image(systemName: "slider.vertical.3")
        }
        .iconButtonStyle(isActive: false)
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Glass Button") {
    HStack(spacing: 16) {
        Button { } label: {
            Label("Settings", systemImage: "gear")
        }
        .glassButtonStyle()

        Button { } label: {
            Label("Quit", systemImage: "power")
        }
        .glassButtonStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Vibrancy Icons") {
    HStack(spacing: 20) {
        VStack {
            Image(systemName: "headphones")
                .font(.title)
                .vibrancyIcon(.primary)
            Text("Primary")
                .font(.caption)
        }

        VStack {
            Image(systemName: "headphones")
                .font(.title)
                .vibrancyIcon(.secondary)
            Text("Secondary")
                .font(.caption)
        }

        VStack {
            Image(systemName: "headphones")
                .font(.title)
                .vibrancyIcon(.tertiary)
            Text("Tertiary")
                .font(.caption)
        }
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
