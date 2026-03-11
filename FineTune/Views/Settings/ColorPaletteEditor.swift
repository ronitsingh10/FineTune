// FineTune/Views/Settings/ColorPaletteEditor.swift
import SwiftUI
import AppKit

// MARK: - Editing target

private enum EditTarget { case primary, accent, background, cellBorder, cellBackground }

// MARK: - Preset definition

private struct ColorPreset {
    let name:        String
    let hue:         Double
    let saturation:  Double
    let brightness:  Double
    let isDark:      Bool
    let isHiContrast: Bool
    // Cell background override — nil = derive from primary (default behaviour)
    let cellBgHue:   Double?
    let cellBgSat:   Double?
    let cellBgBri:   Double?
}

private let presets: [ColorPreset] = [
    // Cell tinting active for all presets in both hi and lo contrast.
    ColorPreset(name: "Default",  hue: 0.583, saturation: 0.80, brightness: 1.00,
                isDark: true,  isHiContrast: true,
                cellBgHue: 0.583, cellBgSat: 0.35, cellBgBri: 0.20),
    ColorPreset(name: "fxSound",  hue: 0.972, saturation: 0.90, brightness: 0.835,
                isDark: true,  isHiContrast: true,
                cellBgHue: 0.972, cellBgSat: 0.40, cellBgBri: 0.18),
    ColorPreset(name: "Midnight", hue: 0.720, saturation: 0.85, brightness: 0.88,
                isDark: true,  isHiContrast: true,
                cellBgHue: 0.700, cellBgSat: 0.55, cellBgBri: 0.35),
    ColorPreset(name: "Amber",    hue: 0.115, saturation: 0.90, brightness: 1.00,
                isDark: true,  isHiContrast: true,
                cellBgHue: 0.115, cellBgSat: 0.45, cellBgBri: 0.20),
    ColorPreset(name: "Forest",   hue: 0.375, saturation: 0.78, brightness: 0.78,
                isDark: true,  isHiContrast: false,
                cellBgHue: 0.375, cellBgSat: 0.65, cellBgBri: 0.38),
    ColorPreset(name: "Rose",     hue: 0.930, saturation: 0.72, brightness: 0.95,
                isDark: false, isHiContrast: false,
                cellBgHue: 0.930, cellBgSat: 0.28, cellBgBri: 0.92),
    ColorPreset(name: "Coral",    hue: 0.040, saturation: 0.80, brightness: 0.95,
                isDark: false, isHiContrast: false,
                cellBgHue: 0.040, cellBgSat: 0.22, cellBgBri: 0.98),
    ColorPreset(name: "Arctic",   hue: 0.570, saturation: 0.55, brightness: 0.92,
                isDark: false, isHiContrast: true,
                cellBgHue: 0.570, cellBgSat: 0.18, cellBgBri: 0.94),
]

// MARK: - Editor

struct ColorPaletteEditor: View {

    @Environment(ThemeManager.self) private var theme
    let onCancel: () -> Void

    // Snapshot for cancel
    @State private var snapshotHue:        Double = 0
    @State private var snapshotSat:        Double = 0
    @State private var snapshotBri:        Double = 0
    @State private var snapshotDark:       Bool   = true
    @State private var snapshotHiContrast: Bool   = true
    @State private var snapshotGlassMode:  Bool   = false
    @State private var snapshotCellBgOn:   Bool   = false
    @State private var snapshotCellBgH:    Double = 0
    @State private var snapshotCellBgS:    Double = 0
    @State private var snapshotCellBgB:    Double = 0
    @State private var snapshotAccentOn:   Bool   = false
    @State private var snapshotAccentH:    Double = 0
    @State private var snapshotAccentS:    Double = 0
    @State private var snapshotAccentB:    Double = 0
    @State private var snapshotBgOn:       Bool   = false
    @State private var snapshotBgH:        Double = 0
    @State private var snapshotBgS:        Double = 0
    @State private var snapshotBgB:        Double = 0
    @State private var snapshotBorderOn:   Bool   = false
    @State private var snapshotBorderH:    Double = 0
    @State private var snapshotBorderS:    Double = 0
    @State private var snapshotBorderB:    Double = 0

    // Saved custom values — restored when user picks "Custom" after a preset
    @State private var savedCustomHue:       Double? = nil
    @State private var savedCustomSat:       Double? = nil
    @State private var savedCustomBri:       Double? = nil
    @State private var savedCustomDark:      Bool?   = nil
    @State private var savedCustomHiContrast: Bool?  = nil
    @State private var savedCustomGlassMode: Bool?   = nil
    @State private var savedCustomCellBgOn:  Bool?   = nil
    @State private var savedCustomCellBgH:   Double? = nil
    @State private var savedCustomCellBgS:   Double? = nil
    @State private var savedCustomCellBgB:   Double? = nil
    @State private var savedCustomAccentOn:  Bool?   = nil
    @State private var savedCustomAccentH:   Double? = nil
    @State private var savedCustomAccentS:   Double? = nil
    @State private var savedCustomAccentB:   Double? = nil
    @State private var savedCustomBgOn:      Bool?   = nil
    @State private var savedCustomBgH:       Double? = nil
    @State private var savedCustomBgS:       Double? = nil
    @State private var savedCustomBgB:       Double? = nil
    @State private var savedCustomBorderOn:  Bool?   = nil
    @State private var savedCustomBorderH:   Double? = nil
    @State private var savedCustomBorderS:   Double? = nil
    @State private var savedCustomBorderB:   Double? = nil

    // Which colour is the HSB editor currently targeting
    @State private var editTarget: EditTarget = .primary

    // Local mirror for sliders
    @State private var hue:        Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0

    // Cell bg local mirror
    @State private var cbHue: Double = 0
    @State private var cbSat: Double = 0
    @State private var cbBri: Double = 0
    // Accent local mirror
    @State private var acHue: Double = 0
    @State private var acSat: Double = 0
    @State private var acBri: Double = 0
    // Background local mirror
    @State private var bgHue: Double = 0
    @State private var bgSat: Double = 0
    @State private var bgBri: Double = 0
    // Cell border local mirror
    @State private var brHue: Double = 0
    @State private var brSat: Double = 0
    @State private var brBri: Double = 0

    @State private var rText: String = ""
    @State private var gText: String = ""
    @State private var bText: String = ""

    @State private var selectedPreset: String = "Custom"
    @State private var isSyncingTarget: Bool = false

    // Computed bindings routed through editTarget
    private var activeHue: Binding<Double> {
        switch editTarget {
        case .primary: return $hue
        case .accent: return $acHue
        case .background: return $bgHue
        case .cellBorder: return $brHue
        case .cellBackground: return $cbHue
        }
    }
    private var activeSat: Binding<Double> {
        switch editTarget {
        case .primary: return $saturation
        case .accent: return $acSat
        case .background: return $bgSat
        case .cellBorder: return $brSat
        case .cellBackground: return $cbSat
        }
    }
    private var activeBri: Binding<Double> {
        switch editTarget {
        case .primary: return $brightness
        case .accent: return $acBri
        case .background: return $bgBri
        case .cellBorder: return $brBri
        case .cellBackground: return $cbBri
        }
    }

    var body: some View {
        ColorPaletteEditorContent(
            selectedPreset: $selectedPreset,
            editTarget: editTarget,
            primaryColor: Color(hue: hue, saturation: saturation, brightness: brightness),
            cellBgColor: cellBgPreviewColor,
            onCancel: restoreAndCancel,
            onPresetChange: handlePresetChange,
            onSelectTarget: setEditTarget,
            preview: previewActive,
            label: activeLabel,
            activeHue: activeHue,
            activeSat: activeSat,
            activeBri: activeBri,
            hueGradient: hueGradient(),
            saturationGradient: saturationGradient(),
            brightnessGradient: brightnessGradient(),
            rgbBinding: binding(for:),
            onApplyRGB: applyRGBFields
        )
        .onAppear(perform: handleAppear)
        .onChange(of: changeKey) { old, new in
            handleChange(old: old, new: new)
        }
    }

    // MARK: - Computed

    private var previewActive: Color {
        switch editTarget {
        case .primary:
            return Color(hue: hue, saturation: saturation, brightness: brightness)
        case .accent:
            return Color(hue: acHue, saturation: acSat, brightness: acBri)
        case .background:
            return Color(hue: bgHue, saturation: bgSat, brightness: bgBri)
        case .cellBorder:
            return Color(hue: brHue, saturation: brSat, brightness: brBri)
        case .cellBackground:
            return Color(hue: cbHue, saturation: cbSat, brightness: cbBri)
        }
    }

    private var cellBgPreviewColor: Color {
        Color(hue: cbHue, saturation: cbSat, brightness: cbBri)
    }

    private var activeLabel: String {
        switch editTarget {
        case .primary: return "Primary Colour"
        case .accent: return "Accent"
        case .background: return "Background"
        case .cellBorder: return "Cell Border"
        case .cellBackground: return "Cell Background"
        }
    }

    private func hueGradient() -> Gradient {
        Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.04).map {
            Color(hue: $0, saturation: 0.85, brightness: 1.0)
        })
    }
    private func saturationGradient() -> Gradient {
        let h = activeHue.wrappedValue; let b = activeBri.wrappedValue
        return Gradient(colors: [
            Color(hue: h, saturation: 0,   brightness: b),
            Color(hue: h, saturation: 1.0, brightness: b)
        ])
    }
    private func brightnessGradient() -> Gradient {
        let h = activeHue.wrappedValue; let s = activeSat.wrappedValue
        return Gradient(colors: [
            Color(hue: h, saturation: s, brightness: 0),
            Color(hue: h, saturation: s, brightness: 1.0)
        ])
    }

    private struct PaletteChangeKey: Equatable {
        let hue: Double
        let saturation: Double
        let brightness: Double
        let cbHue: Double
        let cbSat: Double
        let cbBri: Double
        let acHue: Double
        let acSat: Double
        let acBri: Double
        let bgHue: Double
        let bgSat: Double
        let bgBri: Double
        let brHue: Double
        let brSat: Double
        let brBri: Double
        let isDarkMode: Bool
        let isHiContrast: Bool
        let isGlassMode: Bool
        let editTarget: EditTarget
    }

    private var changeKey: PaletteChangeKey {
        PaletteChangeKey(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            cbHue: cbHue,
            cbSat: cbSat,
            cbBri: cbBri,
            acHue: acHue,
            acSat: acSat,
            acBri: acBri,
            bgHue: bgHue,
            bgSat: bgSat,
            bgBri: bgBri,
            brHue: brHue,
            brSat: brSat,
            brBri: brBri,
            isDarkMode: theme.isDarkMode,
            isHiContrast: theme.isHiContrast,
            isGlassMode: theme.isGlassMode,
            editTarget: editTarget
        )
    }

    // MARK: - Change handlers

    private func handleAppear() {
        snapshotHue        = theme.hue
        snapshotSat        = theme.saturation
        snapshotBri        = theme.brightness
        snapshotDark       = theme.isDarkMode
        snapshotHiContrast = theme.isHiContrast
        snapshotGlassMode  = theme.isGlassMode
        snapshotCellBgOn   = theme.useCustomCellBg
        snapshotCellBgH    = theme.cellBgHue
        snapshotCellBgS    = theme.cellBgSat
        snapshotCellBgB    = theme.cellBgBri
        snapshotAccentOn   = theme.useCustomAccent
        snapshotAccentH    = theme.accentHue
        snapshotAccentS    = theme.accentSat
        snapshotAccentB    = theme.accentBri
        snapshotBgOn       = theme.useCustomBackground
        snapshotBgH        = theme.backgroundHue
        snapshotBgS        = theme.backgroundSat
        snapshotBgB        = theme.backgroundBri
        snapshotBorderOn   = theme.useCustomCellBorder
        snapshotBorderH    = theme.cellBorderHue
        snapshotBorderS    = theme.cellBorderSat
        snapshotBorderB    = theme.cellBorderBri

        hue        = theme.hue
        saturation = theme.saturation
        brightness = theme.brightness
        cbHue      = theme.cellBgHue
        cbSat      = theme.cellBgSat
        cbBri      = theme.cellBgBri
        acHue      = theme.accentHue
        acSat      = theme.accentSat
        acBri      = theme.accentBri
        bgHue      = theme.backgroundHue
        bgSat      = theme.backgroundSat
        bgBri      = theme.backgroundBri
        brHue      = theme.cellBorderHue
        brSat      = theme.cellBorderSat
        brBri      = theme.cellBorderBri

        syncRGBFromActive()
        selectedPreset = matchPresetName()
    }

    private func handleChange(old: PaletteChangeKey, new: PaletteChangeKey) {
        if old.hue != new.hue { handleHueChange(new.hue) }
        if old.saturation != new.saturation { handleSaturationChange(new.saturation) }
        if old.brightness != new.brightness { handleBrightnessChange(new.brightness) }
        if old.cbHue != new.cbHue { handleCellBgHueChange(new.cbHue) }
        if old.cbSat != new.cbSat { handleCellBgSatChange(new.cbSat) }
        if old.cbBri != new.cbBri { handleCellBgBriChange(new.cbBri) }
        if old.acHue != new.acHue { handleAccentHueChange(new.acHue) }
        if old.acSat != new.acSat { handleAccentSatChange(new.acSat) }
        if old.acBri != new.acBri { handleAccentBriChange(new.acBri) }
        if old.bgHue != new.bgHue { handleBackgroundHueChange(new.bgHue) }
        if old.bgSat != new.bgSat { handleBackgroundSatChange(new.bgSat) }
        if old.bgBri != new.bgBri { handleBackgroundBriChange(new.bgBri) }
        if old.brHue != new.brHue { handleBorderHueChange(new.brHue) }
        if old.brSat != new.brSat { handleBorderSatChange(new.brSat) }
        if old.brBri != new.brBri { handleBorderBriChange(new.brBri) }
        if old.isDarkMode != new.isDarkMode || old.isHiContrast != new.isHiContrast || old.isGlassMode != new.isGlassMode {
            markCustom()
        }
        if old.editTarget != new.editTarget {
            syncRGBFromActive()
        }
    }

    private func handlePresetChange(_ name: String) {
        if name == "Custom" {
            restoreCustom()
        } else if let preset = presets.first(where: { $0.name == name }) {
            saveCustomIfNeeded()
            applyPreset(preset)
        }
    }

    private func handleHueChange(_ v: Double) {
        theme.hue = v
        syncRGBFromActive()
        markCustom()
    }
    private func handleSaturationChange(_ v: Double) {
        theme.saturation = v
        syncRGBFromActive()
        markCustom()
    }
    private func handleBrightnessChange(_ v: Double) {
        theme.brightness = v
        syncRGBFromActive()
        markCustom()
    }
    private func handleCellBgHueChange(_ v: Double) {
        theme.cellBgHue = v
        if editTarget == .cellBackground { theme.useCustomCellBg = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleCellBgSatChange(_ v: Double) {
        theme.cellBgSat = v
        if editTarget == .cellBackground { theme.useCustomCellBg = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleCellBgBriChange(_ v: Double) {
        theme.cellBgBri = v
        if editTarget == .cellBackground { theme.useCustomCellBg = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleAccentHueChange(_ v: Double) {
        theme.accentHue = v
        if editTarget == .accent && !isSyncingTarget { theme.useCustomAccent = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleAccentSatChange(_ v: Double) {
        theme.accentSat = v
        if editTarget == .accent && !isSyncingTarget { theme.useCustomAccent = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleAccentBriChange(_ v: Double) {
        theme.accentBri = v
        if editTarget == .accent && !isSyncingTarget { theme.useCustomAccent = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleBackgroundHueChange(_ v: Double) {
        theme.backgroundHue = v
        if editTarget == .background && !isSyncingTarget { theme.useCustomBackground = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleBackgroundSatChange(_ v: Double) {
        theme.backgroundSat = v
        if editTarget == .background && !isSyncingTarget { theme.useCustomBackground = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleBackgroundBriChange(_ v: Double) {
        theme.backgroundBri = v
        if editTarget == .background && !isSyncingTarget { theme.useCustomBackground = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleBorderHueChange(_ v: Double) {
        theme.cellBorderHue = v
        if editTarget == .cellBorder && !isSyncingTarget { theme.useCustomCellBorder = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleBorderSatChange(_ v: Double) {
        theme.cellBorderSat = v
        if editTarget == .cellBorder && !isSyncingTarget { theme.useCustomCellBorder = true }
        syncRGBFromActive()
        markCustom()
    }
    private func handleBorderBriChange(_ v: Double) {
        theme.cellBorderBri = v
        if editTarget == .cellBorder && !isSyncingTarget { theme.useCustomCellBorder = true }
        syncRGBFromActive()
        markCustom()
    }

    // MARK: - Target selection

    private func setEditTarget(_ target: EditTarget) {
        guard editTarget != target else { return }
        isSyncingTarget = true
        switch target {
        case .primary:
            hue = theme.hue
            saturation = theme.saturation
            brightness = theme.brightness
        case .accent:
            if theme.useCustomAccent {
                acHue = theme.accentHue; acSat = theme.accentSat; acBri = theme.accentBri
            } else {
                let hsb = hsbFromColor(theme.accentColor)
                acHue = hsb.h; acSat = hsb.s; acBri = hsb.b
                theme.accentHue = acHue
                theme.accentSat = acSat
                theme.accentBri = acBri
                theme.useCustomAccent = true
            }
        case .background:
            if theme.useCustomBackground {
                bgHue = theme.backgroundHue; bgSat = theme.backgroundSat; bgBri = theme.backgroundBri
            } else {
                let hsb = hsbFromColor(theme.backgroundOverlayColor)
                bgHue = hsb.h; bgSat = hsb.s; bgBri = hsb.b
            }
        case .cellBorder:
            if theme.useCustomCellBorder {
                brHue = theme.cellBorderHue; brSat = theme.cellBorderSat; brBri = theme.cellBorderBri
            } else {
                let hsb = hsbFromColor(theme.cellBorderColor)
                brHue = hsb.h; brSat = hsb.s; brBri = hsb.b
            }
        case .cellBackground:
            cbHue = theme.cellBgHue; cbSat = theme.cellBgSat; cbBri = theme.cellBgBri
        }
        editTarget = target
        syncRGBFromActive()
        isSyncingTarget = false
    }

    private func hsbFromColor(_ color: Color) -> (h: Double, s: Double, b: Double) {
        let nc = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.blue
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nc.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    // MARK: - RGB sync

    private func syncRGBFromActive() {
        let h = activeHue.wrappedValue
        let s = activeSat.wrappedValue
        let b = activeBri.wrappedValue
        let nc = NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
            .usingColorSpace(.sRGB) ?? NSColor.blue
        rText = String(Int(round(nc.redComponent   * 255)))
        gText = String(Int(round(nc.greenComponent * 255)))
        bText = String(Int(round(nc.blueComponent  * 255)))
    }

    private func applyRGBFields() {
        guard let r = Int(rText), let g = Int(gText), let b = Int(bText),
              (0...255).contains(r), (0...255).contains(g), (0...255).contains(b)
        else { syncRGBFromActive(); return }
        let nc = NSColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, bv: CGFloat = 0, a: CGFloat = 0
        nc.getHue(&h, saturation: &s, brightness: &bv, alpha: &a)
        activeHue.wrappedValue  = Double(h)
        activeSat.wrappedValue  = Double(s)
        activeBri.wrappedValue  = Double(bv)
    }

    private func binding(for channel: String) -> Binding<String> {
        switch channel { case "R": return $rText; case "G": return $gText; default: return $bText }
    }

    // MARK: - Preset helpers

    private func matchPresetName() -> String {
        if theme.useCustomAccent || theme.useCustomBackground || theme.useCustomCellBorder {
            return "Custom"
        }
        if theme.isGlassMode { return "Custom" }
        return presets.first(where: {
            abs($0.hue - theme.hue) < 0.001 &&
            abs($0.saturation - theme.saturation) < 0.001 &&
            abs($0.brightness - theme.brightness) < 0.001 &&
            $0.isDark == theme.isDarkMode &&
            $0.isHiContrast == theme.isHiContrast
        })?.name ?? "Custom"
    }

    private func markCustom() {
        // Always mark custom if primary/mode doesn't match any preset,
        // OR if the cell background has been independently customised.
        if matchPresetName() == "Custom" || theme.useCustomCellBg && !cellBgMatchesCurrentPreset() {
            selectedPreset = "Custom"
        }
    }

    private func cellBgMatchesCurrentPreset() -> Bool {
        guard let preset = presets.first(where: { $0.name == selectedPreset }) else { return false }
        if let ph = preset.cellBgHue, let ps = preset.cellBgSat, let pb = preset.cellBgBri {
            return abs(ph - cbHue) < 0.001 && abs(ps - cbSat) < 0.001 && abs(pb - cbBri) < 0.001
        }
        // Preset has no cell bg override — custom if user has enabled one
        return !theme.useCustomCellBg
    }

    private func saveCustomIfNeeded() {
        guard selectedPreset == "Custom" else { return }
        savedCustomHue        = hue
        savedCustomSat        = saturation
        savedCustomBri        = brightness
        savedCustomDark       = theme.isDarkMode
        savedCustomHiContrast = theme.isHiContrast
        savedCustomGlassMode  = theme.isGlassMode
        savedCustomCellBgOn   = theme.useCustomCellBg
        savedCustomCellBgH    = cbHue
        savedCustomCellBgS    = cbSat
        savedCustomCellBgB    = cbBri
        savedCustomAccentOn   = theme.useCustomAccent
        savedCustomAccentH    = acHue
        savedCustomAccentS    = acSat
        savedCustomAccentB    = acBri
        savedCustomBgOn       = theme.useCustomBackground
        savedCustomBgH        = bgHue
        savedCustomBgS        = bgSat
        savedCustomBgB        = bgBri
        savedCustomBorderOn   = theme.useCustomCellBorder
        savedCustomBorderH    = brHue
        savedCustomBorderS    = brSat
        savedCustomBorderB    = brBri
    }

    private func restoreCustom() {
        guard let sh = savedCustomHue else { return }
        hue        = sh
        saturation = savedCustomSat ?? saturation
        brightness = savedCustomBri ?? brightness
        theme.hue        = hue
        theme.saturation = saturation
        theme.brightness = brightness
        theme.isDarkMode   = savedCustomDark       ?? theme.isDarkMode
        theme.isHiContrast = savedCustomHiContrast ?? theme.isHiContrast
        theme.isGlassMode  = savedCustomGlassMode  ?? theme.isGlassMode
        theme.useCustomCellBg = savedCustomCellBgOn ?? false
        cbHue = savedCustomCellBgH ?? cbHue
        cbSat = savedCustomCellBgS ?? cbSat
        cbBri = savedCustomCellBgB ?? cbBri
        theme.cellBgHue = cbHue
        theme.cellBgSat = cbSat
        theme.cellBgBri = cbBri
        theme.useCustomAccent = savedCustomAccentOn ?? false
        acHue = savedCustomAccentH ?? acHue
        acSat = savedCustomAccentS ?? acSat
        acBri = savedCustomAccentB ?? acBri
        theme.accentHue = acHue
        theme.accentSat = acSat
        theme.accentBri = acBri
        theme.useCustomBackground = savedCustomBgOn ?? false
        bgHue = savedCustomBgH ?? bgHue
        bgSat = savedCustomBgS ?? bgSat
        bgBri = savedCustomBgB ?? bgBri
        theme.backgroundHue = bgHue
        theme.backgroundSat = bgSat
        theme.backgroundBri = bgBri
        theme.useCustomCellBorder = savedCustomBorderOn ?? false
        brHue = savedCustomBorderH ?? brHue
        brSat = savedCustomBorderS ?? brSat
        brBri = savedCustomBorderB ?? brBri
        theme.cellBorderHue = brHue
        theme.cellBorderSat = brSat
        theme.cellBorderBri = brBri
        syncRGBFromActive()
    }

    private func applyPreset(_ preset: ColorPreset) {
        hue        = preset.hue
        saturation = preset.saturation
        brightness = preset.brightness
        theme.hue        = preset.hue
        theme.saturation = preset.saturation
        theme.brightness = preset.brightness
        theme.isDarkMode   = preset.isDark
        theme.isHiContrast = preset.isHiContrast
        theme.isGlassMode  = false   // presets are dark/light; exit glass mode

        theme.useCustomAccent = false
        theme.useCustomBackground = false
        theme.useCustomCellBorder = false
        acHue = preset.hue; acSat = preset.saturation; acBri = preset.brightness
        bgHue = preset.hue; bgSat = preset.saturation; bgBri = preset.brightness
        brHue = preset.hue; brSat = preset.saturation; brBri = preset.brightness
        theme.accentHue = acHue; theme.accentSat = acSat; theme.accentBri = acBri
        theme.backgroundHue = bgHue; theme.backgroundSat = bgSat; theme.backgroundBri = bgBri
        theme.cellBorderHue = brHue; theme.cellBorderSat = brSat; theme.cellBorderBri = brBri

        // All presets now have explicit cellBg values.
        // useCustomCellBg is true only for lo-contrast presets where tint is active.
        let bh = preset.cellBgHue ?? preset.hue
        let bs = preset.cellBgSat ?? 0.0
        let bb = preset.cellBgBri ?? (preset.isDark ? 0.18 : 0.90)
        cbHue = bh; cbSat = bs; cbBri = bb
        theme.cellBgHue = bh; theme.cellBgSat = bs; theme.cellBgBri = bb
        theme.useCustomCellBg = true
        selectedPreset = preset.name
        // Reset edit target to primary so the sliders show primary values on preset switch.
        editTarget = .primary
        syncRGBFromActive()
    }

    // MARK: - Views

    // MARK: - Cancel / restore

    private func restoreAndCancel() {
        theme.hue          = snapshotHue
        theme.saturation   = snapshotSat
        theme.brightness   = snapshotBri
        theme.isDarkMode   = snapshotDark
        theme.isHiContrast = snapshotHiContrast
        theme.isGlassMode  = snapshotGlassMode
        theme.useCustomCellBg = snapshotCellBgOn
        theme.cellBgHue    = snapshotCellBgH
        theme.cellBgSat    = snapshotCellBgS
        theme.cellBgBri    = snapshotCellBgB
        theme.useCustomAccent = snapshotAccentOn
        theme.accentHue = snapshotAccentH
        theme.accentSat = snapshotAccentS
        theme.accentBri = snapshotAccentB
        theme.useCustomBackground = snapshotBgOn
        theme.backgroundHue = snapshotBgH
        theme.backgroundSat = snapshotBgS
        theme.backgroundBri = snapshotBgB
        theme.useCustomCellBorder = snapshotBorderOn
        theme.cellBorderHue = snapshotBorderH
        theme.cellBorderSat = snapshotBorderS
        theme.cellBorderBri = snapshotBorderB
        onCancel()
    }
}

private struct ColorPaletteEditorContent: View {
    @Binding var selectedPreset: String
    let editTarget: EditTarget
    let primaryColor: Color
    let cellBgColor: Color
    let onCancel: () -> Void
    let onPresetChange: (String) -> Void
    let onSelectTarget: (EditTarget) -> Void
    let preview: Color
    let label: String
    @Binding var activeHue: Double
    @Binding var activeSat: Double
    @Binding var activeBri: Double
    let hueGradient: Gradient
    let saturationGradient: Gradient
    let brightnessGradient: Gradient
    let rgbBinding: (String) -> Binding<String>
    let onApplyRGB: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorPaletteHeaderView(onCancel: onCancel)
            ColorPalettePresetSection(
                selectedPreset: $selectedPreset,
                editTarget: editTarget,
                primaryColor: primaryColor,
                cellBgColor: cellBgColor,
                onPresetChange: onPresetChange,
                onSelectTarget: onSelectTarget
            )
            ColorPaletteEditorSection(
                preview: preview,
                label: label,
                activeHue: $activeHue,
                activeSat: $activeSat,
                activeBri: $activeBri,
                hueGradient: hueGradient,
                saturationGradient: saturationGradient,
                brightnessGradient: brightnessGradient,
                rgbBinding: rgbBinding,
                onApplyRGB: onApplyRGB
            )
            ColorPaletteAppearanceSection()
        }
    }
}

// MARK: - Palette strip with numeric field

private struct ColorPaletteHeaderView: View {
    let onCancel: () -> Void
    var body: some View {
        HStack {
            Text("COLOUR PALETTE")
                .sectionHeaderStyle()
            Spacer()
            Button(action: onCancel) {
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
    }
}

private struct ColorPalettePresetSection: View {
    @Environment(ThemeManager.self) private var theme
    @Binding var selectedPreset: String
    let editTarget: EditTarget
    let primaryColor: Color
    let cellBgColor: Color
    let onPresetChange: (String) -> Void
    let onSelectTarget: (EditTarget) -> Void

    var body: some View {
        ExpandableGlassRow(isExpanded: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PaletteSectionLabel(text: "PRESET")
                    Spacer()
                    Picker("", selection: $selectedPreset) {
                        ForEach(presets, id: \.name) { Text($0.name).tag($0.name) }
                        Text("Custom").tag("Custom")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .onChange(of: selectedPreset) { _, name in onPresetChange(name) }
                }
                HStack(spacing: 10) {
                    PaletteTargetSwatch(
                        label: "Accent",
                        fill: theme.separatorAccentColor,
                        active: editTarget == .accent
                    ) { onSelectTarget(.accent) }
                    PaletteTargetSwatch(
                        label: "Cell Border",
                        fill: .clear,
                        active: editTarget == .cellBorder,
                        swatchBorderColor: theme.cellBorderColor,
                        swatchBorderWidth: 2
                    ) { onSelectTarget(.cellBorder) }
                    PaletteTargetSwatch(
                        label: "Background",
                        fill: theme.backgroundOverlayColor,
                        active: editTarget == .background
                    ) { onSelectTarget(.background) }
                }
                HStack(spacing: 10) {
                    PaletteTargetSwatch(
                        label: "Primary",
                        fill: primaryColor,
                        active: editTarget == .primary
                    ) { onSelectTarget(.primary) }
                    PaletteTargetSwatch(
                        label: "Cell Background",
                        fill: .clear,
                        active: editTarget == .cellBackground,
                        swatchBorderColor: .gray,
                        swatchBorderWidth: 2
                    ) { onSelectTarget(.cellBackground) }
                }
            }
            .padding(.vertical, 6)
        } expandedContent: { EmptyView() }
    }
}

private struct ColorPaletteEditorSection: View {
    let preview: Color
    let label: String
    @Binding var activeHue: Double
    @Binding var activeSat: Double
    @Binding var activeBri: Double
    let hueGradient: Gradient
    let saturationGradient: Gradient
    let brightnessGradient: Gradient
    let rgbBinding: (String) -> Binding<String>
    let onApplyRGB: () -> Void

    var body: some View {
        ExpandableGlassRow(isExpanded: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(preview)
                        .frame(width: 38, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Spacer()
                }
                PaletteStrip(label: "Hue",        value: $activeHue,  gradient: hueGradient,        hi: 360, unit: "°")
                PaletteStrip(label: "Saturation", value: $activeSat,  gradient: saturationGradient, hi: 100, unit: "%")
                PaletteStrip(label: "Brightness", value: $activeBri,  gradient: brightnessGradient, hi: 100, unit: "%")

                HStack(spacing: 8) {
                    ForEach(["R", "G", "B"], id: \.self) { ch in
                        RGBField(label: ch, text: rgbBinding(ch), onCommit: onApplyRGB)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 6)
        } expandedContent: { EmptyView() }
    }
}

private struct ColorPaletteAppearanceSection: View {
    @Environment(ThemeManager.self) private var theme

    /// A 3-way ThemeMode computed from isDarkMode + isGlassMode,
    /// so PaletteTabPicker gets a single Binding<ThemeMode>.
    private var themeModeBinding: Binding<ThemeMode> {
        Binding(
            get: {
                if theme.isGlassMode { return .glass }
                return theme.isDarkMode ? .dark : .light
            },
            set: { mode in
                switch mode {
                case .dark:
                    theme.isDarkMode  = true
                    theme.isGlassMode = false
                case .light:
                    theme.isDarkMode  = false
                    theme.isGlassMode = false
                case .glass:
                    theme.isDarkMode  = true   // glass always uses dark NSAppearance
                    theme.isGlassMode = true
                }
            }
        )
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: false) {
            VStack(alignment: .leading, spacing: 10) {
                PaletteSectionLabel(text: "APPEARANCE")
                PaletteTabPicker(
                    selection: themeModeBinding,
                    options: [
                        (.dark,  "moon.fill",    "Dark"),
                        (.light, "sun.max.fill", "Light"),
                        (.glass, "drop.fill",    "Glass"),
                    ]
                )
                if theme.isGlassMode {
                    Text("Liquid Glass uses a maximally transparent frosted material with iridescent highlights — the iOS 26 aesthetic.")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                PaletteSectionLabel(text: "CONTRAST")
                PaletteTabPicker(
                    selection: Binding(get: { theme.isHiContrast },
                                       set: { theme.isHiContrast = $0 }),
                    options: [
                        (true,  "circle.grid.cross.fill", "Hi-Contrast"),
                        (false, "circle.grid.cross",      "Lo-Contrast")
                    ]
                )
                if !theme.isHiContrast && !theme.isGlassMode {
                    Text("In lo-contrast, the background uses a pastel shade of your primary colour instead.")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } expandedContent: { EmptyView() }
    }
}

private struct PaletteSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .tracking(1.0)
    }
}

private struct PaletteTargetSwatch: View {
    let label: String
    let fill: Color
    let active: Bool
    var baseColor: Color? = nil
    var swatchBorderColor: Color? = .white.opacity(0.15)
    var swatchBorderWidth: CGFloat = 1
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(baseColor ?? fill)
                    if baseColor != nil {
                        RoundedRectangle(cornerRadius: 6).fill(fill)
                    }
                    if let sc = swatchBorderColor {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(sc, lineWidth: swatchBorderWidth)
                    }
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(active ? DesignTokens.Colors.interactiveDefault : .white.opacity(0.15),
                                      lineWidth: active ? 1.5 : 1)
                )
                Text(label)
                    .font(.system(size: 9, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DesignTokens.Colors.interactiveDefault : DesignTokens.Colors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}


private struct PaletteStrip: View {
    let label:    String
    @Binding var value: Double
    let gradient: Gradient
    let hi:       Double
    let unit:     String

    @State private var fieldText:     String = ""
    @State private var isEditingField = false

    private let trackH: CGFloat = 10
    private let thumbR: CGFloat = 7
    private var displayNum: Double { value * hi }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer()
                TextField("", text: $fieldText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .frame(width: 30)
                    .multilineTextAlignment(.trailing)
                    .onAppear   { fieldText = fmt(displayNum) }
                    .onChange(of: value) { _, _ in if !isEditingField { fieldText = fmt(displayNum) } }
                    .onSubmit   { commitField(); isEditingField = false }
                    .onTapGesture { isEditingField = true }
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 8, alignment: .leading)
            }
            GeometryReader { geo in
                let w  = geo.size.width
                let tx = thumbR + value * (w - thumbR * 2)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: trackH / 2)
                        .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(height: trackH)
                        .overlay(RoundedRectangle(cornerRadius: trackH / 2)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
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
                    isEditingField = false
                    value = max(0, min(1, (d.location.x - thumbR) / (w - thumbR * 2)))
                })
            }
            .frame(height: thumbR * 2)
        }
    }

    private func fmt(_ v: Double) -> String { String(Int(round(v))) }
    private func commitField() {
        guard let n = Double(fieldText), n >= 0, n <= hi else { fieldText = fmt(displayNum); return }
        value = n / hi
    }
}

// MARK: - RGB editable field

private struct RGBField: View {
    let label: String
    @Binding var text: String
    let onCommit: () -> Void
    var body: some View {
        VStack(spacing: 3) {
            TextField("", text: $text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)))
                .onSubmit(onCommit)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }
}

// MARK: - Tab picker (unchanged)

private struct PaletteTabPicker<T: Equatable>: View {
    @Binding var selection: T
    let options: [(value: T, icon: String, label: String)]
    @Namespace private var ns
    private let h: CGFloat = 26; private let r: CGFloat = 6
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = selection == opt.value
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { selection = opt.value }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: opt.icon).font(.system(size: 10)).symbolRenderingMode(.hierarchical)
                        Text(opt.label).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.55))
                    .frame(height: h).padding(.horizontal, 10)
                    .background {
                        if active { RoundedRectangle(cornerRadius: r).fill(.white.opacity(0.10))
                            .matchedGeometryEffect(id: "ptab", in: ns) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: r + 3).fill(.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: r + 3).strokeBorder(.white.opacity(0.08), lineWidth: 0.5)))
    }
}
