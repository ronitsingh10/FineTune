// FineTune/Views/DesignSystem/VisualEffectBackground.swift
import SwiftUI
import AppKit

/// Native macOS 26+ glass surface with a visual-effect fallback for older
/// supported releases. Keeping this as an AppKit bridge lets the popup use
/// the real Liquid Glass implementation without raising the app's deployment
/// target from macOS 15.4.
struct NativeGlassBackground: NSViewRepresentable {
    enum Style: Equatable {
        case regular
        case clear
    }

    var cornerRadius: CGFloat = 16
    var style: Style = .regular
    var interactive = false

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            apply(to: view)
            return view
        }

        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to nsView: NSView) {
        if #available(macOS 26.0, *), let glassView = nsView as? NSGlassEffectView {
            glassView.cornerRadius = cornerRadius
            glassView.style = style == .regular ? .regular : .clear

            if #available(macOS 27.0, *) {
                glassView.effectIsInteractive = interactive
            }
            return
        }

        guard let visualEffectView = nsView as? NSVisualEffectView else { return }
        visualEffectView.material = style == .regular ? .popover : .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
    }
}

/// A frosted glass background using NSVisualEffectView, Apple's documented
/// translucent material primitive. The default `.popover` material renders
/// as proper light/dark glass and matches the platform Control Center and
/// Notification Center surfaces.
struct VisualEffectBackground: NSViewRepresentable {
    /// Apple's documented material for popover and menu-bar panels. Renders
    /// vibrant translucency in both appearances. The previous `.hudWindow`
    /// default was designed for dark floating overlays and washed out badly
    /// in light mode.
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Colors

extension Color {
    /// Popup background overlay - uses theme-aware color from DesignTokens
    /// Darker than before for more contrast with floating glass rows
    static var popupBackgroundOverlay: Color { DesignTokens.Colors.popupOverlay }
}

// MARK: - View Extensions

extension View {
    /// Applies the popup's translucent glass background. Adapts to light and
    /// dark via the host window's appearance. On macOS 26+, the underlying
    /// NSGlassEffectView supplies the platform Liquid Glass surface; older
    /// releases keep the documented `.popover` material fallback.
    /// Name kept for source compatibility; rename pending a follow-up sweep.
    func darkGlassBackground() -> some View {
        self
            .background {
                NativeGlassBackground(
                    cornerRadius: DesignTokens.Dimensions.cornerRadius,
                    style: .regular,
                    interactive: true
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: DesignTokens.Dimensions.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
                .allowsHitTesting(false)
            }
    }

    /// Applies the lifted-card background used by the EQ panel.
    /// Light reads as a white card on the popup glass; dark reads as a
    /// translucent surface on the dark glass. Replaces the prior recessed
    /// treatment which read as a heavy gray block on whiter light glass.
    func eqCardBackground() -> some View {
        modifier(LiftedCardBackgroundModifier())
    }
}

// MARK: - Lifted Card Background Modifier (EQ panel)

/// Native inset glass card used by the EQ panel.
/// macOS 26+ gets a clear Liquid Glass surface; older releases fall back to
/// the closest AppKit HUD material. The hairline and shadow preserve the
/// card's separation from the surrounding row glass.
///
/// The shadow uses a literal `Color.black.opacity(0.06)`. Shadows are a
/// depth cue, not a chromatic surface, and remain readable in both modes
/// without an appearance-aware token.
struct LiftedCardBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                NativeGlassBackground(
                    cornerRadius: DesignTokens.Dimensions.rowRadius,
                    style: .clear,
                    interactive: true
                )
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DesignTokens.Dimensions.rowRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: DesignTokens.Dimensions.rowRadius,
                    style: .continuous
                )
                    .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(0.06),
                radius: 1.5,
                x: 0,
                y: 0.5
            )
    }
}

// MARK: - Previews

#Preview("Dark Glass Popup Background") {
    VStack(spacing: 16) {
        Text("OUTPUT DEVICES")
            .sectionHeaderStyle()
        Text("Dark frosted glass background")
            .foregroundStyle(.primary)
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 300)
    .darkGlassBackground()
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cornerRadius))
    .environment(\.colorScheme, .dark)
}

#Preview("EQ Card - Lifted") {
    VStack(spacing: 8) {
        Text("EQ Card - Lifted")
            .foregroundStyle(.secondary)
        HStack {
            ForEach(0..<5) { _ in
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 20, height: 60)
            }
        }
    }
    .padding()
    .eqCardBackground()
    .padding()
    .darkGlassBackground()
}
