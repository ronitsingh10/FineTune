// FineTune/Views/Settings/ColorPaletteEditor.swift
import SwiftUI

/// Slides in as an overlay when the paintpalette button is pressed on the
/// Special Effects tab.
///
/// Changes are applied to ThemeManager IMMEDIATELY (live preview).
/// ✓ (external top-right button) = CONFIRM — keeps changes and closes.
/// ✕ (inside this editor)        = CANCEL  — restores previous state and closes.
struct ColorPaletteEditor: View {

    @Environment(ThemeManager.self) private var theme

    /// Called when ✕ is tapped — restores state then dismisses.
    let onCancel: () -> Void

    // Snapshot taken on appear so cancel can restore
    @State private var snapshotHue:        Double = 0
    @State private var snapshotSat:        Double = 0
    @State private var snapshotBri:        Double = 0
    @State private var snapshotDark:       Bool   = true
    @State private var snapshotHiContrast: Bool   = true

    // Local mirror for responsive sliders (propagated live to ThemeManager)
    @State private var hue:        Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Header ──────────────────────────────────────────────────
            HStack {
                Text("COLOUR PALETTE")
                    .sectionHeaderStyle()
                Spacer()
                // Reset to defaults button
                Button { applyDefaults() } label: {
                    Text("Default")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                .help("Restore default dark aqua theme")
                // ✕ cancel — reverts all changes
                Button { restoreAndCancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                        .frame(minWidth: DesignTokens.Dimensions.minTouchTarget,
                               minHeight: DesignTokens.Dimensions.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cancel — discard changes")
            }

            // ── Section 1: Primary colour ────────────────────────────────
            ExpandableGlassRow(isExpanded: false) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(previewAccent)
                            .frame(width: 38, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                            )
                        Text("Primary Colour")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                        Spacer()
                    }
                    PaletteStrip(label: "Hue",
                                 value: $hue,
                                 gradient: hueGradient())
                    PaletteStrip(label: "Saturation",
                                 value: $saturation,
                                 gradient: saturationGradient())
                    PaletteStrip(label: "Brightness",
                                 value: $brightness,
                                 gradient: brightnessGradient())
                }
                .padding(.vertical, 6)
            } expandedContent: { EmptyView() }

            // ── Section 2: Appearance ────────────────────────────────────
            // Hi-contrast: plain dark or light background.
            // Lo-contrast: pastel-tinted background (overrides dark/light).
            ExpandableGlassRow(isExpanded: false) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("APPEARANCE")
                    PaletteTabPicker(
                        selection: Binding(get: { theme.isDarkMode },
                                           set: { theme.isDarkMode = $0 }),
                        options: [
                            (true,  "moon.fill",    "Dark"),
                            (false, "sun.max.fill", "Light")
                        ]
                    )
                    if !theme.isHiContrast {
                        Text("In lo-contrast, the background uses a pastel shade of your primary colour instead.")
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } expandedContent: { EmptyView() }

            // ── Section 3: Contrast ──────────────────────────────────────
            // Hi-contrast: vivid primary accent + grey/white cell borders + plain bg.
            // Lo-contrast: desaturated accent + primary-tinted borders + pastel bg.
            ExpandableGlassRow(isExpanded: false) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("CONTRAST")
                    PaletteTabPicker(
                        selection: Binding(get: { theme.isHiContrast },
                                           set: { theme.isHiContrast = $0 }),
                        options: [
                            (true,  "circle.grid.cross.fill", "Hi-Contrast"),
                            (false, "circle.grid.cross",      "Lo-Contrast")
                        ]
                    )
                    // Live preview of how borders and background look
                    HStack(spacing: 10) {
                        contrastSwatch(
                            label: "Accent",
                            fill: theme.accentColor
                        )
                        contrastSwatch(
                            label: "Cell border",
                            fill: Color.clear,
                            borderColor: theme.cellBorderColor,
                            borderWidth: 2
                        )
                        contrastSwatch(
                            label: "Background",
                            fill: theme.backgroundOverlayColor.opacity(0.6)
                        )
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } expandedContent: { EmptyView() }
        }
        .onAppear {
            // Snapshot current state for cancel/revert
            snapshotHue        = theme.hue
            snapshotSat        = theme.saturation
            snapshotBri        = theme.brightness
            snapshotDark       = theme.isDarkMode
            snapshotHiContrast = theme.isHiContrast
            // Initialise local slider state
            hue        = theme.hue
            saturation = theme.saturation
            brightness = theme.brightness
        }
        // Propagate slider changes live to ThemeManager
        .onChange(of: hue)        { _, v in theme.hue = v }
        .onChange(of: saturation) { _, v in theme.saturation = v }
        .onChange(of: brightness) { _, v in theme.brightness = v }
    }

    // MARK: - Helpers

    private var previewAccent: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private func hueGradient() -> Gradient {
        Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.04).map {
            Color(hue: $0, saturation: 0.85, brightness: 1.0)
        })
    }
    private func saturationGradient() -> Gradient {
        Gradient(colors: [
            Color(hue: hue, saturation: 0,   brightness: brightness),
            Color(hue: hue, saturation: 1.0, brightness: brightness)
        ])
    }
    private func brightnessGradient() -> Gradient {
        Gradient(colors: [
            Color(hue: hue, saturation: saturation, brightness: 0),
            Color(hue: hue, saturation: saturation, brightness: 1.0)
        ])
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .tracking(1.0)
    }

    @ViewBuilder
    private func contrastSwatch(label: String,
                                 fill: Color,
                                 borderColor: Color = .white.opacity(0.15),
                                 borderWidth: CGFloat = 1) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(fill)
                .frame(height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Cancel / restore

    private func restoreAndCancel() {
        theme.hue        = snapshotHue
        theme.saturation = snapshotSat
        theme.brightness = snapshotBri
        theme.isDarkMode  = snapshotDark
        theme.isHiContrast = snapshotHiContrast
        onCancel()
    }

    private func applyDefaults() {
        // Default: dark mode, hi-contrast, macOS blue hue
        let defaultHue: Double = 0.583
        let defaultSat: Double = 0.80
        let defaultBri: Double = 1.00
        theme.hue        = defaultHue
        theme.saturation = defaultSat
        theme.brightness = defaultBri
        theme.isDarkMode  = true
        theme.isHiContrast = true
        hue        = defaultHue
        saturation = defaultSat
        brightness = defaultBri
    }
}

// MARK: - Colour strip (hue / sat / bri slider)

private struct PaletteStrip: View {
    let label: String
    @Binding var value: Double
    let gradient: Gradient

    private let trackH: CGFloat = 10
    private let thumbR: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            GeometryReader { geo in
                let w  = geo.size.width
                let tx = thumbR + value * (w - thumbR * 2)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: trackH / 2)
                        .fill(LinearGradient(gradient: gradient,
                                             startPoint: .leading,
                                             endPoint: .trailing))
                        .frame(height: trackH)
                        .overlay(
                            RoundedRectangle(cornerRadius: trackH / 2)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                        )
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbR * 2, height: thumbR * 2)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                        .offset(x: tx - thumbR)
                        .allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    value = max(0, min(1, (d.location.x - thumbR) / (w - thumbR * 2)))
                })
            }
            .frame(height: thumbR * 2)
        }
    }
}

// MARK: - Icon + label tab picker

private struct PaletteTabPicker<T: Equatable>: View {
    @Binding var selection: T
    let options: [(value: T, icon: String, label: String)]
    @Namespace private var ns
    private let h: CGFloat = 26
    private let r: CGFloat = 6

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = selection == opt.value
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        selection = opt.value
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: opt.icon)
                            .font(.system(size: 10))
                            .symbolRenderingMode(.hierarchical)
                        Text(opt.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.55))
                    .frame(height: h)
                    .padding(.horizontal, 10)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: r)
                                .fill(.white.opacity(0.10))
                                .matchedGeometryEffect(id: "ptab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: r + 3)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: r + 3)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        )
    }
}
