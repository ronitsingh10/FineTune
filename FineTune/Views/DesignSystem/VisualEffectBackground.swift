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

// MARK: - Liquid Glass background layers (iOS 26 aesthetic)

/// The multi-layer stack that produces the iOS 26 "Liquid Glass" look on macOS.
///
/// Layer order (bottom → top):
///  1. NSVisualEffectView with `.fullScreenUI` — maximally transparent frosted blur
///  2. Iridescent prismatic AngularGradient — the colour-shift caustic effect
///  3. Accent hue wash — very subtle tint from the user's chosen colour
///  4. Top-edge specular highlight — simulates light catching the glass rim
private struct LiquidGlassOverlay: View {
    @Environment(ThemeManager.self) private var theme
    /// Rotating the angular gradient by the hue shifts the prismatic spread
    /// so each accent colour produces a complementary shimmer.
    private var prismRotation: Double { theme.hue * 360 }

    var body: some View {
        ZStack {
            // 1. Ultra-transparent blur — fullScreenUI is the clearest macOS material
            VisualEffectBackground(material: .fullScreenUI, blendingMode: .behindWindow)

            // 2. Prismatic iridescent caustic overlay (very low opacity).
            //    startAngle offsets by the user's hue so each colour choice
            //    produces a unique complementary shimmer spread.
            AngularGradient(
                colors: [
                    Color(hue: (theme.hue + 0.00).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 1.0).opacity(0.055),
                    Color(hue: (theme.hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 1.0).opacity(0.040),
                    Color(hue: (theme.hue + 0.25).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 1.0).opacity(0.030),
                    Color(hue: (theme.hue + 0.40).truncatingRemainder(dividingBy: 1), saturation: 0.4, brightness: 1.0).opacity(0.025),
                    Color(hue: (theme.hue + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 1.0).opacity(0.030),
                    Color(hue: (theme.hue + 0.70).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 1.0).opacity(0.040),
                    Color(hue: (theme.hue + 0.85).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 1.0).opacity(0.050),
                    Color(hue: (theme.hue + 0.00).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 1.0).opacity(0.055),
                ],
                center: .topLeading,
                startAngle: .degrees(prismRotation),
                endAngle: .degrees(prismRotation + 360)
            )
            .blendMode(.plusLighter)

            // 3. Subtle accent-hue wash so the user's chosen colour still
            //    shows through in glass mode
            theme.primaryColor.opacity(0.045)

            // 4. Top-edge specular — light catching the glass top rim
            LinearGradient(
                colors: [
                    Color.white.opacity(0.10),
                    Color.white.opacity(0.02),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.22)
            )
        }
    }
}

// MARK: - Glass background modifier (reads ThemeManager for tint + colorScheme)

private struct GlassBackgroundModifier: ViewModifier {
    @Environment(ThemeManager.self) private var theme

    func body(content: Content) -> some View {
        if theme.isGlassMode {
            // Liquid Glass: swap to the iOS 26-style layered blur
            content.background(LiquidGlassOverlay())
        } else {
            // Standard dark/light modes: original tinted hudWindow blur
            content
                .background(theme.backgroundOverlayColor)
                .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
        }
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

#Preview("Liquid Glass") {
    let tm = ThemeManager()
    let _ = { tm.isGlassMode = true }()
    VStack(spacing: 16) {
        Text("OUTPUT DEVICES").bold()
        Text("Liquid Glass — iOS 26 aesthetic")
    }
    .padding(20)
    .frame(width: 300)
    .darkGlassBackground()
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .environment(tm)
}
