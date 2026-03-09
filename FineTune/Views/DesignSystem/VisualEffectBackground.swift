// FineTune/Views/DesignSystem/VisualEffectBackground.swift
import SwiftUI
import AppKit

/// A frosted glass background using NSVisualEffectView.
/// Appearance (dark/light) is driven by the SwiftUI colorScheme environment —
/// no hardcoded darkAqua so ThemeManager's isDarkMode takes full effect.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        // Appearance synced in updateNSView
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        // Follow SwiftUI's colorScheme (set by ThemeManager via preferredColorScheme)
        nsView.appearance = context.environment.colorScheme == .dark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }
}

// MARK: - Glass background modifier (reads ThemeManager for tint + colorScheme)

private struct GlassBackgroundModifier: ViewModifier {
    @Environment(ThemeManager.self) private var theme

    func body(content: Content) -> some View {
        content
            .background(theme.backgroundOverlayColor)
            .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
    }
}

// MARK: - View Extensions

extension View {
    /// Applies a theme-aware glass background.
    /// Dark hi-contrast → original dark popup look.
    /// Light hi-contrast → lighter blur.
    /// Lo-contrast → pastel primary tint over the blur.
    func darkGlassBackground() -> some View {
        modifier(GlassBackgroundModifier())
    }

    func eqPanelBackground() -> some View {
        modifier(EQPanelBackgroundModifier())
    }
}

// MARK: - EQ Panel Background Modifier

struct EQPanelBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(DesignTokens.Colors.recessedBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
            }
    }
}

// MARK: - Previews

#Preview("Dark Glass - Hi-Contrast") {
    VStack(spacing: 16) {
        Text("OUTPUT DEVICES").bold()
        Text("Dark frosted glass background")
    }
    .padding(20)
    .frame(width: 300)
    .darkGlassBackground()
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .environment(ThemeManager())
}
