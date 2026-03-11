// FineTune/Views/FXPanelView.swift
import SwiftUI

// MARK: - FXPanelView (top-level, owns SOUNDS System/Apps toggle)

struct FXPanelView: View {
    let settings: FXSettings
    let onSettingsChanged: (FXSettings) -> Void
    let isFXPowerEnabled: Bool
    let onFXPowerToggled: (Bool) -> Void

    // FX device routing
    let outputDevices:        [AudioDevice]
    let defaultDeviceUID:     String?
    let fxDeviceMode:         DeviceSelectionMode
    let fxDeviceUID:          String?
    let fxSelectedDeviceUIDs: Set<String>
    let fxFollowsDefault:     Bool
    let onFXDeviceModeChange: (DeviceSelectionMode) -> Void
    let onFXDeviceSelected:   (String) -> Void
    let onFXDevicesSelected:  (Set<String>) -> Void
    let onFXFollowDefault:    () -> Void

    // Injected from MenuBarPopupView for the APPS sub-view
    let displayableApps: [DisplayableApp]
    let expandedEQAppID: String?
    let onEQToggle: (String) -> Void
    let audioEngine: AudioEngine

    enum SoundTarget { case system, apps }
    @State private var soundTarget: SoundTarget = .system
    @AppStorage("fxSoundTarget") private var savedTarget: String = "system"

    init(settings: FXSettings,
         onSettingsChanged: @escaping (FXSettings) -> Void,
         isFXPowerEnabled: Bool,
         onFXPowerToggled: @escaping (Bool) -> Void,
         outputDevices: [AudioDevice],
         defaultDeviceUID: String?,
         fxDeviceMode: DeviceSelectionMode,
         fxDeviceUID: String?,
         fxSelectedDeviceUIDs: Set<String>,
         fxFollowsDefault: Bool,
         onFXDeviceModeChange: @escaping (DeviceSelectionMode) -> Void,
         onFXDeviceSelected:   @escaping (String) -> Void,
         onFXDevicesSelected:  @escaping (Set<String>) -> Void,
         onFXFollowDefault:    @escaping () -> Void,
         displayableApps: [DisplayableApp],
         expandedEQAppID: String?,
         onEQToggle: @escaping (String) -> Void,
         audioEngine: AudioEngine) {
        self.settings             = settings
        self.onSettingsChanged    = onSettingsChanged
        self.isFXPowerEnabled     = isFXPowerEnabled
        self.onFXPowerToggled     = onFXPowerToggled
        self.outputDevices        = outputDevices
        self.defaultDeviceUID     = defaultDeviceUID
        self.fxDeviceMode         = fxDeviceMode
        self.fxDeviceUID          = fxDeviceUID
        self.fxSelectedDeviceUIDs = fxSelectedDeviceUIDs
        self.fxFollowsDefault     = fxFollowsDefault
        self.onFXDeviceModeChange = onFXDeviceModeChange
        self.onFXDeviceSelected   = onFXDeviceSelected
        self.onFXDevicesSelected  = onFXDevicesSelected
        self.onFXFollowDefault    = onFXFollowDefault
        self.displayableApps      = displayableApps
        self.expandedEQAppID      = expandedEQAppID
        self.onEQToggle           = onEQToggle
        self.audioEngine          = audioEngine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header: SOUNDS  [SYSTEM][APPS]
            HStack(spacing: 8) {
                Text("SOUNDS")
                    .sectionHeaderStyle()
                SoundTargetPicker(selection: $soundTarget)
                Spacer()
            }
            .padding(.bottom, 2)

            if soundTarget == .system {
                FXSystemPanel(
                    settings: settings,
                    fxEditingUID: audioEngine.fxEditingUID,
                    onSettingsChanged: onSettingsChanged,
                    isFXPowerEnabled: isFXPowerEnabled,
                    onFXPowerToggled: onFXPowerToggled,
                    outputDevices: outputDevices,
                    defaultDeviceUID: defaultDeviceUID,
                    fxDeviceMode: fxDeviceMode,
                    fxDeviceUID: fxDeviceUID,
                    fxSelectedDeviceUIDs: fxSelectedDeviceUIDs,
                    fxFollowsDefault: fxFollowsDefault,
                    onFXDeviceModeChange: onFXDeviceModeChange,
                    onFXDeviceSelected: onFXDeviceSelected,
                    onFXDevicesSelected: onFXDevicesSelected,
                    onFXFollowDefault: onFXFollowDefault,
                    audioEngine: audioEngine
                )
            } else {
                FXAppsPanel(
                    displayableApps: displayableApps,
                    expandedEQAppID: expandedEQAppID,
                    onEQToggle: onEQToggle,
                    audioEngine: audioEngine
                )
            }
        }
        .onAppear { soundTarget = savedTarget == "apps" ? .apps : .system }
        .onChange(of: soundTarget) { _, v in savedTarget = v == .apps ? "apps" : "system" }
    }
}

// MARK: - Sound Target Picker (matches primary tab group style exactly)

private struct SoundTargetPicker: View {
    @Binding var selection: FXPanelView.SoundTarget
    @Namespace private var ns
    @Environment(ThemeManager.self) private var theme

    private let buttonSize: CGFloat = 26
    private let cornerRadius: CGFloat = 6   // matches DesignTokens.Dimensions.buttonRadius

    var body: some View {
        let _ = theme.themeVersion  // force re-render when derived colours change
        HStack(spacing: 2) {
            tab("System", target: .system)
            tab("Apps",   target: .apps)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius + 3)
                .fill(theme.separatorAccentColor.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius + 3)
                        .strokeBorder(theme.separatorAccentColor, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func tab(_ label: String, target: FXPanelView.SoundTarget) -> some View {
        let active = selection == target
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selection = target }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.5))
                .frame(height: buttonSize)
                .padding(.horizontal, 8)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(theme.separatorAccentColor)
                            .matchedGeometryEffect(id: "soundTarget", in: ns)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FX Element Separator

private struct FXSeparator: View {
    @Environment(ThemeManager.self) private var theme
    var body: some View {
        let _ = theme.themeVersion  // force re-render when derived colours change
        theme.separatorAccentColor
            .frame(height: 0.5)
            .padding(.horizontal, 2)
    }
}

// MARK: - FX System Panel (preset + sliders + EQ — all in glass cells)

private struct FXSystemPanel: View {
    let settings: FXSettings
    let onSettingsChanged: (FXSettings) -> Void
    let isFXPowerEnabled: Bool
    let onFXPowerToggled: (Bool) -> Void
    let audioEngine: AudioEngine

    // Used to detect device-picker switches even when the settings value is identical
    let fxEditingUID: String?

    // Device routing
    let outputDevices:        [AudioDevice]
    let defaultDeviceUID:     String?
    let fxDeviceMode:         DeviceSelectionMode
    let fxDeviceUID:          String?
    let fxSelectedDeviceUIDs: Set<String>
    let fxFollowsDefault:     Bool
    let onFXDeviceModeChange: (DeviceSelectionMode) -> Void
    let onFXDeviceSelected:   (String) -> Void
    let onFXDevicesSelected:  (Set<String>) -> Void
    let onFXFollowDefault:    () -> Void

    @Environment(ThemeManager.self) private var theme

    /// Resolved accent RGB — computed in the SwiftUI body so it always reflects
    /// the current theme at render time, not at NSViewRepresentable callback time.
    private var accentRGB: (CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        (NSColor(theme.primaryColor).usingColorSpace(.sRGB) ?? .systemBlue)
            .getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r, g, b)
    }
    @State private var local: FXSettings
    @State private var selectedPreset: FXPreset? = .general
    @State private var isDirty: Bool = false
    @State private var fxAreaHovered = false

    init(settings: FXSettings,
         fxEditingUID: String?,
         onSettingsChanged: @escaping (FXSettings) -> Void,
         isFXPowerEnabled: Bool,
         onFXPowerToggled: @escaping (Bool) -> Void,
         outputDevices: [AudioDevice],
         defaultDeviceUID: String?,
         fxDeviceMode: DeviceSelectionMode,
         fxDeviceUID: String?,
         fxSelectedDeviceUIDs: Set<String>,
         fxFollowsDefault: Bool,
         onFXDeviceModeChange: @escaping (DeviceSelectionMode) -> Void,
         onFXDeviceSelected:   @escaping (String) -> Void,
         onFXDevicesSelected:  @escaping (Set<String>) -> Void,
         onFXFollowDefault:    @escaping () -> Void,
         audioEngine: AudioEngine) {
        self.settings             = settings
        self.onSettingsChanged    = onSettingsChanged
        self.isFXPowerEnabled     = isFXPowerEnabled
        self.onFXPowerToggled     = onFXPowerToggled
        self.outputDevices        = outputDevices
        self.defaultDeviceUID     = defaultDeviceUID
        self.fxDeviceMode         = fxDeviceMode
        self.fxDeviceUID          = fxDeviceUID
        self.fxSelectedDeviceUIDs = fxSelectedDeviceUIDs
        self.fxFollowsDefault     = fxFollowsDefault
        self.onFXDeviceModeChange = onFXDeviceModeChange
        self.onFXDeviceSelected   = onFXDeviceSelected
        self.onFXDevicesSelected  = onFXDevicesSelected
        self.onFXFollowDefault    = onFXFollowDefault
        self.audioEngine          = audioEngine
        self.fxEditingUID         = fxEditingUID
        _local = State(initialValue: settings)

        let targetKey = fxEditingUID ?? "__system__"
        let presetIDKey = "lastFXPresetID.\(targetKey)"
        let presetDirtyKey = "lastFXPresetDirty.\(targetKey)"

        // Restore preset and dirty state from persistence (scoped per editing target).
        // isDirty is NEVER forced true here — only user interaction (markDirtyAndEmit)
        // sets it. This prevents the asterisk appearing on tab-return without edits.
        if let match = settings.matchingPreset() {
            _selectedPreset = State(initialValue: match)
            _isDirty = State(initialValue: false)
            UserDefaults.standard.set(match.rawValue, forKey: presetIDKey)
            UserDefaults.standard.set(false, forKey: presetDirtyKey)
        } else {
            let savedID    = UserDefaults.standard.string(forKey: presetIDKey) ?? FXPreset.general.rawValue
            let savedDirty = UserDefaults.standard.bool(forKey: presetDirtyKey)
            let restored   = FXPreset(rawValue: savedID) ?? .general
            _selectedPreset = State(initialValue: restored)
            _isDirty = State(initialValue: savedDirty)
        }
    }

    private var presetScopeKey: String { fxEditingUID ?? "__system__" }
    private var presetIDKey: String { "lastFXPresetID.\(presetScopeKey)" }
    private var presetDirtyKey: String { "lastFXPresetDirty.\(presetScopeKey)" }

    private var presetLabel: String {
        guard let p = selectedPreset else { return "General" }
        return isDirty ? "\(p.name) *" : p.name
    }

    var body: some View {
        VStack(spacing: 8) {
            // ── Cell 1: Preset + Device Picker + Enable ──────────────────
            ExpandableGlassRow(isExpanded: false) {
                HStack(spacing: 8) {
                    FXPresetDropdown(label: presetLabel) { preset in
                        selectedPreset = preset
                        isDirty = false
                        UserDefaults.standard.set(false, forKey: presetDirtyKey)
                        UserDefaults.standard.set(preset.rawValue, forKey: presetIDKey)
                        local = preset.settings
                        onSettingsChanged(local)
                    }
                    Spacer()
                    // Device picker — same component used in app rows
                    DevicePicker(
                        devices: outputDevices,
                        selectedDeviceUID: fxDeviceUID ?? defaultDeviceUID ?? "",
                        selectedDeviceUIDs: fxSelectedDeviceUIDs,
                        isFollowingDefault: fxFollowsDefault,
                        defaultDeviceUID: defaultDeviceUID,
                        mode: fxDeviceMode,
                        onModeChange: onFXDeviceModeChange,
                        onDeviceSelected: onFXDeviceSelected,
                        onDevicesSelected: onFXDevicesSelected,
                        onSelectFollowDefault: onFXFollowDefault,
                        showModeToggle: true
                    )
                    // Power button — solid accent fill when on, hollow ring when off
                    Button {
                        onFXPowerToggled(!isFXPowerEnabled)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isFXPowerEnabled ? theme.primaryColor : Color.clear)
                                .frame(width: 26, height: 26)
                            Circle()
                                .strokeBorder(isFXPowerEnabled
                                              ? theme.primaryColor
                                              : DesignTokens.Colors.textSecondary,
                                              lineWidth: 1.5)
                                .frame(width: 26, height: 26)
                            Image(systemName: "power")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isFXPowerEnabled ? .black.opacity(0.85)
                                                                 : DesignTokens.Colors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isFXPowerEnabled ? "Disable FX" : "Enable FX")
                    .animation(.easeInOut(duration: 0.15), value: isFXPowerEnabled)
                }
                .frame(height: DesignTokens.Dimensions.rowContentHeight)
            } expandedContent: { EmptyView() }

            FXSeparator()

            // ── Cell 2: Spectrum Visualizer ──────────────────────────────
            ExpandableGlassRow(isExpanded: false) {
                FXSpectrumView(isEnabled: isFXPowerEnabled,
                               audioEngine: audioEngine,
                               accentR: accentRGB.0,
                               accentG: accentRGB.1,
                               accentB: accentRGB.2)
                    .frame(height: 48)
                    .padding(.vertical, 4)
            } expandedContent: { EmptyView() }

            // ── Cell 3: FX Sliders ───────────────────────────────────────
            ExpandableGlassRow(isExpanded: false) {
                VStack(alignment: .leading, spacing: 6) {
                    fxSlider("Clarity",
                             tooltip: "Enhances and elevates high-end fidelity and presence.",
                             kp: \.clarity,       set: { local.clarity = $0 })
                    fxSlider("Ambience",
                             tooltip: "Thickens and smooths audio with controlled reverberation.",
                             kp: \.ambience,      set: { local.ambience = $0 })
                    fxSlider("Surround Sound",
                             tooltip: "Widens the left-right balance for expansive, wide sound.",
                             kp: \.surroundSound, set: { local.surroundSound = $0 })
                    fxSlider("Dynamic Boost",
                             tooltip: "Increases the overall volume and balance with responsive processing.",
                             kp: \.dynamicBoost,  set: { local.dynamicBoost = $0 })
                    fxSlider("Bass Boost",
                             tooltip: "Boosts low end for full, impactful response.",
                             kp: \.bassBoost,     set: { local.bassBoost = $0 })
                }
                .padding(.vertical, 4)
                .onHover { fxAreaHovered = $0 }
            } expandedContent: { EmptyView() }
            .saturation(isFXPowerEnabled ? 1 : 0).opacity(isFXPowerEnabled ? 1 : 0.55)
            .disabled(!isFXPowerEnabled)

            FXSeparator()

            // ── Cell 4: EQ Curve + Dials ─────────────────────────────────
            ExpandableGlassRow(isExpanded: false) {
                VStack(spacing: 0) {
                    FXEQCurve(gains: Binding(
                        get: { local.eqGains },
                        set: { local.eqGains = $0; markDirtyAndEmit() }
                    ))
                    .frame(height: 84)
                    .padding(.horizontal, 4)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.separatorAccentColor.opacity(0.45), lineWidth: 0.8)
                    )

                    FXDialRow(freqs: Binding(
                        get: { local.eqFreqs },
                        set: { local.eqFreqs = $0; markDirtyAndEmit() }
                    ))
                    .padding(.top, 10)
                    .padding(.horizontal, 4)
                }
                .padding(.vertical, 4)
            } expandedContent: { EmptyView() }
            .saturation(isFXPowerEnabled ? 1 : 0).opacity(isFXPowerEnabled ? 1 : 0.55)
            .disabled(!isFXPowerEnabled)
        }
        .onChange(of: settings) { _, v in
            local = v
            if let m = v.matchingPreset() {
                selectedPreset = m
                isDirty = false
                UserDefaults.standard.set(false, forKey: presetDirtyKey)
                UserDefaults.standard.set(m.rawValue, forKey: presetIDKey)
            }
        }
        // Also trigger when the editing target switches — covers the case where two devices
        // have identical settings values so onChange(of: settings) wouldn't fire.
        // `audioEngine.fxSettingsForEditing` is now a stored @Observable property updated
        // atomically with fxEditingUID, so it is always correct here.
        .onChange(of: fxEditingUID) { _, _ in
            let current = audioEngine.fxSettingsForEditing
            local = current
            if let m = current.matchingPreset() {
                selectedPreset = m
                isDirty = false
                UserDefaults.standard.set(false, forKey: presetDirtyKey)
                UserDefaults.standard.set(m.rawValue, forKey: presetIDKey)
            } else {
                let savedID = UserDefaults.standard.string(forKey: presetIDKey) ?? FXPreset.general.rawValue
                selectedPreset = FXPreset(rawValue: savedID) ?? .general
                // Restore saved dirty state for this target's settings
                let savedDirty = UserDefaults.standard.bool(forKey: presetDirtyKey)
                isDirty = savedDirty
            }
        }
    }

    @ViewBuilder
    private func fxSlider(_ label: String, tooltip: String,
                           kp: KeyPath<FXSettings, Int>,
                           set: @escaping (Int) -> Void) -> some View {
        FXSliderRow(
            label: label,
            value: Binding(get: { local[keyPath: kp] }, set: { set($0); markDirtyAndEmit() }),
            showValue: fxAreaHovered
        )
        .help(tooltip)
    }

    private func markDirtyAndEmit() {
        isDirty = true
        let presetID = selectedPreset?.rawValue ?? FXPreset.general.rawValue
        UserDefaults.standard.set(true, forKey: presetDirtyKey)
        UserDefaults.standard.set(presetID, forKey: presetIDKey)
        onSettingsChanged(local)
    }
}

// MARK: - FX Apps Panel (EQ per app, no volume controls)

private struct FXAppsPanel: View {
    let displayableApps: [DisplayableApp]
    let expandedEQAppID: String?
    let onEQToggle: (String) -> Void
    let audioEngine: AudioEngine

    var body: some View {
        if displayableApps.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .font(.title)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                    Text("No apps playing audio")
                        .font(.callout)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                Spacer()
            }
            .padding(.vertical, 20)
        } else {
            VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(displayableApps) { displayableApp in
                    FXAppRow(
                        displayableApp: displayableApp,
                        isEQExpanded: expandedEQAppID == displayableApp.id,
                        onEQToggle: { onEQToggle(displayableApp.id) },
                        audioEngine: audioEngine
                    )
                }
            }
        }
    }
}

// MARK: - FX App Row (icon + name + EQ button, no volume controls)

private struct FXAppRow: View {
    let displayableApp: DisplayableApp
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let audioEngine: AudioEngine

    @State private var isRowHovered = false
    @State private var isEQButtonHovered = false

    private var eqButtonColor: Color {
        if isEQExpanded { return DesignTokens.Colors.interactiveActive }
        else if isEQButtonHovered { return DesignTokens.Colors.interactiveHover }
        else { return DesignTokens.Colors.interactiveDefault }
    }

    private var appName: String {
        switch displayableApp {
        case .active(let app): return app.name
        case .pinnedInactive(let info): return info.displayName
        }
    }

    private var eqSettings: EQSettings {
        switch displayableApp {
        case .active(let app): return audioEngine.getEQSettings(for: app)
        case .pinnedInactive(let info): return audioEngine.getEQSettingsForInactive(identifier: info.persistenceIdentifier)
        }
    }

    private func handleEQChange(_ s: EQSettings) {
        switch displayableApp {
        case .active(let app): audioEngine.setEQSettings(s, for: app)
        case .pinnedInactive(let info): audioEngine.setEQSettingsForInactive(s, identifier: info.persistenceIdentifier)
        }
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                // App icon
                Image(nsImage: displayableApp.icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                // App name
                Text(appName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // EQ toggle button
                Button { onEQToggle() } label: {
                    ZStack {
                        Image(systemName: "slider.vertical.3")
                            .opacity(isEQExpanded ? 0 : 1)
                            .rotationEffect(.degrees(isEQExpanded ? 90 : 0))
                        Image(systemName: "xmark")
                            .opacity(isEQExpanded ? 1 : 0)
                            .rotationEffect(.degrees(isEQExpanded ? 0 : -90))
                    }
                    .font(.system(size: 12))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(eqButtonColor)
                    .frame(minWidth: DesignTokens.Dimensions.minTouchTarget,
                           minHeight: DesignTokens.Dimensions.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isEQButtonHovered = $0 }
                .help(isEQExpanded ? "Close Equalizer" : "Equalizer")
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEQExpanded)
                .animation(DesignTokens.Animation.hover, value: isEQButtonHovered)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            FXAppEQWrapper(
                initialSettings: eqSettings,
                onSettingsChanged: { handleEQChange($0) }
            )
        }
    }
}

// MARK: - Preset dropdown

private struct FXPresetDropdown: View {
    let label: String
    let onSelect: (FXPreset) -> Void
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        Menu {
            ForEach(FXPreset.allCases) { preset in
                Button(preset.name) { onSelect(preset) }
            }
        } label: {
            HStack(spacing: 0) {
                Text(label)
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 200, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.separatorAccentColor.opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(theme.primaryColor.opacity(0.55), lineWidth: 1.0)
                    )
            )
        }
        .menuStyle(.automatic)
        .fixedSize()
    }
}

// MARK: - FX Slider row
// Label above; value text always sits to the right of the thumb.
// The usable track is shortened by `labelReserve` pts on the right so even
// "10" (the widest value) never overlaps or flips sides.

private struct FXSliderRow: View {
    let label: String
    @Binding var value: Int
    let showValue: Bool

    @Environment(ThemeManager.self) private var theme

    private let steps        = 10
    private let thumbR: CGFloat   = 7
    private let valueGap: CGFloat = 5
    private let labelReserve: CGFloat = 22   // reserved on right for "10"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            GeometryReader { geo in
                let trackW = geo.size.width - labelReserve
                let frac   = CGFloat(value) / CGFloat(steps)
                let thumbX = (thumbR + frac * (trackW - thumbR * 2))
                    .clamped(thumbR, trackW - thumbR)
                let labelCx = thumbX + thumbR + valueGap + 7
                let accent  = theme.primaryColor

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: trackW, height: 3)

                    Capsule()
                        .fill(accent)
                        .frame(width: thumbX, height: 3)

                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbR * 2, height: thumbR * 2)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .offset(x: thumbX - thumbR)

                    if showValue {
                        Text("\(value)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(accent)
                            .fixedSize()
                            .position(x: labelCx, y: 7)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let raw = drag.location.x / trackW * CGFloat(steps)
                    value = min(steps, max(0, Int(raw.rounded())))
                })
                .animation(.easeInOut(duration: 0.08), value: showValue)
            }
            .frame(height: 14)
        }
    }
}

// MARK: - EQ Curve
// Dots at column centers (i+0.5)*w/9. Fill goes straight down from the endpoints
// (not forced to zero) — no mountain effect. Labels only on hover/drag.

private struct FXEQCurve: View {
    @Binding var gains: [Float]

    @State private var isHovering   = false
    @State private var draggingBand = -1
    @State private var dragStartY: CGFloat  = 0
    @State private var dragStartGain: Float = 0
    @State private var hoverBand: Int = -1   // which band the cursor is over (-1 = none)

    @Environment(ThemeManager.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let labelH: CGFloat = 13
    private let n = 9

    private func colCenter(_ i: Int, width: CGFloat) -> CGFloat {
        (CGFloat(i) + 0.5) * width / CGFloat(n)
    }

    private func yFor(_ gain: Float, height: CGFloat) -> CGFloat {
        let plotH = height - labelH
        return labelH + plotH * 0.5 - CGFloat(gain / 12.0) * plotH * 0.44
    }

    private func bandFor(x: CGFloat, width: CGFloat) -> Int {
        min(n-1, max(0, Int((x / (width / CGFloat(n))).rounded(.down))))
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let accent = theme.primaryColor
            let isDark = colorScheme == .dark
            // In light lo-contrast the pastel background makes faint lines invisible — boost opacity
            let lightLC = !isDark && !theme.isHiContrast
            let gridColor    = isDark ? Color.white.opacity(0.12) : Color.black.opacity(lightLC ? 0.28 : 0.14)
            let midlineColor = isDark ? Color.white.opacity(0.24) : Color.black.opacity(lightLC ? 0.40 : 0.24)
            let labelColor = isDark ? Color.white.opacity(0.65) : Color.black.opacity(0.65)
            let labelActiveColor = isDark ? Color.white : Color.black
            let canvasBackground = isDark
                ? Color.black.opacity(theme.isHiContrast ? 0.30 : 0.24)
                : Color.white.opacity(lightLC ? 0.24 : 0.18)

            Canvas { ctx, sz in
                let midY = labelH + (sz.height - labelH) * 0.5
                let colW = sz.width / CGFloat(n)
                let ctrl = colW * 0.4

                // Grid verticals — dashed, gradient from accent (top) to dim (bottom)
                for i in 0..<n {
                    let x = colCenter(i, width: sz.width)
                    var p = Path(); p.move(to: CGPoint(x: x, y: labelH))
                    p.addLine(to: CGPoint(x: x, y: sz.height))
                    ctx.stroke(p, with: .linearGradient(
                        Gradient(stops: [
                            .init(color: accent.opacity(0.55), location: 0),
                            .init(color: gridColor,            location: 1)
                        ]),
                        startPoint: CGPoint(x: x, y: labelH),
                        endPoint:   CGPoint(x: x, y: sz.height)
                    ), style: StrokeStyle(lineWidth: 0.5, dash: [2.5, 3.0]))
                }
                // Midline — full width
                var mid = Path()
                mid.move(to: CGPoint(x: 0, y: midY))
                mid.addLine(to: CGPoint(x: sz.width, y: midY))
                ctx.stroke(mid, with: .color(midlineColor),
                           style: StrokeStyle(lineWidth: 0.5, dash: [3.0, 2.5]))

                let pts = (0..<n).map { i in
                    CGPoint(x: colCenter(i, width: sz.width), y: yFor(gains[i], height: sz.height))
                }

                // Gradient fill — extends to full width at the edge dot heights
                // Left: horizontal run from x=0 at pts[0].y; right: run to x=width at pts[n-1].y
                let maxGain = gains.map { abs($0) }.max() ?? 0
                let fillOp  = Double(0.33 + (maxGain / 12.0) * 0.38)
                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: sz.height))
                fill.addLine(to: CGPoint(x: 0, y: pts[0].y))          // left edge at first gain
                fill.addLine(to: pts[0])                                // horizontal to first dot
                for i in 1..<n {
                    fill.addCurve(to: pts[i],
                        control1: CGPoint(x: pts[i-1].x + ctrl, y: pts[i-1].y),
                        control2: CGPoint(x: pts[i].x   - ctrl, y: pts[i].y))
                }
                fill.addLine(to: CGPoint(x: sz.width, y: pts[n-1].y)) // horizontal from last dot
                fill.addLine(to: CGPoint(x: sz.width, y: sz.height))   // right edge down
                fill.closeSubpath()
                let topY = pts.map(\.y).min() ?? labelH
                ctx.fill(fill, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: accent.opacity(fillOp), location: 0),
                        .init(color: accent.opacity(0),      location: 1)
                    ]),
                    startPoint: CGPoint(x: sz.width / 2, y: min(topY, midY)),
                    endPoint:   CGPoint(x: sz.width / 2, y: sz.height),
                    options: []
                ))

                // Curve line — solid, also extended to full width at edge heights
                var line = Path()
                line.move(to: CGPoint(x: 0, y: pts[0].y))
                line.addLine(to: pts[0])
                for i in 1..<n {
                    line.addCurve(to: pts[i],
                        control1: CGPoint(x: pts[i-1].x + ctrl, y: pts[i-1].y),
                        control2: CGPoint(x: pts[i].x   - ctrl, y: pts[i].y))
                }
                line.addLine(to: CGPoint(x: sz.width, y: pts[n-1].y))
                ctx.stroke(line, with: .color(accent),
                           style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))

                // Dots + labels
                for i in 0..<n {
                    let p = pts[i]
                    let isDrag = (i == draggingBand)
                    let dotR: CGFloat = isDrag ? 5.5 : 4.5
                    if isDrag {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x-dotR-3, y: p.y-dotR-3,
                                                        width: (dotR+3)*2, height: (dotR+3)*2)),
                                 with: .color(accent.opacity(0.22)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x-dotR, y: p.y-dotR,
                                                    width: dotR*2, height: dotR*2)),
                             with: .color(accent))

                    if isHovering || isDrag {
                        let val = gains[i]
                        let sign = val > 0 ? "+" : ""
                        let txt = val == 0 ? "+0" : "\(sign)\(Int(val.rounded()))"
                        ctx.draw(
                            Text(txt)
                                .font((isDrag
                                    ? Font.system(size: 9, weight: .bold)
                                    : Font.system(size: 8)).monospacedDigit())
                                .foregroundColor(isDrag ? labelActiveColor : labelColor),
                            at: CGPoint(x: p.x, y: p.y - 10), anchor: .center
                        )
                    }
                }
            }
            .background(canvasBackground)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if draggingBand == -1 {
                        draggingBand  = bandFor(x: drag.startLocation.x, width: size.width)
                        dragStartY    = drag.startLocation.y
                        dragStartGain = gains[draggingBand]
                    }
                    gains[draggingBand] = min(12, max(-12,
                        dragStartGain + Float(dragStartY - drag.location.y) * 0.25))
                }
                .onEnded { _ in draggingBand = -1 }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    isHovering = true
                    hoverBand  = bandFor(x: loc.x, width: size.width)
                case .ended:
                    isHovering = false
                    hoverBand  = -1
                }
            }
            .help(hoverBand >= 0 ? fxBandTooltips[hoverBand] : "")
        }
    }
}

// MARK: - Dial row (equal columns matching curve)

private struct FXDialRow: View {
    @Binding var freqs: [Double]
    private let n = 9

    var body: some View {
        GeometryReader { geo in
            let colW = geo.size.width / CGFloat(n)
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { i in
                    FXFreqDial(
                        freq: Binding(
                            get: { i < freqs.count ? freqs[i] : fxEQBandRanges[i].min },
                            set: { v in if i < freqs.count { freqs[i] = v } }
                        ),
                        range: fxEQBandRanges[i],
                        bandIndex: i
                    )
                    .frame(width: colW)
                }
            }
        }
        .frame(height: 52)
    }
}

// MARK: - Frequency Dial

private let fxBandTooltips: [String] = [
    "Super-low Bass. Increase this for more rumble and \"thump\"; decrease it if there's too much boominess.",
    "Center of Bass. Increase this for a fuller low end; decrease it if the bass sounds overwhelming.",
    "Low-Mid Range. Increase this to make vocals sound rich and warm; decrease it to help control sources that sound loud and muffled.",
    "Low-Mid Range Focal. Increase this to bring out electric strings and vocal volume; decrease it to reduce any \"boxy\" tones.",
    "Center-Mid Range. Increase this to drastically boost rhythm sources and snare hits; decrease it to cut out \"nasal\" tones.",
    "High-Mid Range. Increase this to get more harmonics; decrease it to improve beats that have too much \"clickiness\" or orchestral sources that are piercing.",
    "Lower-High Range. Increase this for more vocal clarity and articulation; decrease it and move the frequency wheel up and down to find and cut out overly loud \"S\" and \"T\" sounds.",
    "Center-High Range. Increase this to make your audio sound more like it's in an airy, large space; decrease it to help with room noises and unwanted echoing.",
    "Highest Range. Increase this to give your sound more of a crisp tone, with lots of overtones; decrease it to remove hiss or painfully high sounds."
]

private let fxDialTooltip = "This wheel adjusts which frequencies this EQ band targets - up or down to reach different frequencies and pitches. The EQ slider above controls the gain of this band: increase to boost, decrease to cut a portion of your audio's frequencies without modifying the rest of your sound. Drag around the dial's perimeter to change."

private struct FXFreqDial: View {
    @Binding var freq: Double
    let range: (min: Double, max: Double)
    let bandIndex: Int

    @State private var isHovered   = false
    @State private var dragging    = false
    // Circular drag: track the angle the user started at
    @State private var dragStartAngle: Double = 0
    @State private var dragStartFreq:  Double = 0

    @Environment(ThemeManager.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private static let startDeg: Double = 225.0
    private static let sweepDeg: Double = 270.0

    private var fraction: Double {
        ((freq - range.min) / max(1, range.max - range.min)).clamped(0, 1)
    }
    private var indicatorDeg: Double { Self.startDeg + fraction * Self.sweepDeg }

    private var freqLabel: String {
        freq >= 1000
            ? String(format: "%.2f kHz", freq / 1000)
            : String(format: "%.0f Hz", freq)
    }

    // Convert a drag point relative to dial center → angle in degrees [0, 360)
    private func angleDeg(from point: CGPoint, center: CGPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let rad = atan2(dy, dx)
        let deg = rad * 180 / .pi + 90   // 0° = top
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    // Map an on-dial angle to a fraction within the sweep arc
    private func fractionFor(angle: Double) -> Double? {
        // Sweep starts at startDeg, ends at startDeg + sweepDeg (modulo 360)
        // startDeg = 225°, endDeg = 495° = 135°
        // We remap angle into [0, 360) relative to startDeg
        var relative = (angle - Self.startDeg + 360).truncatingRemainder(dividingBy: 360)
        // Clamp: if outside the sweep, reject (dragging into the gap)
        if relative > Self.sweepDeg + 15 { return nil }
        return (relative / Self.sweepDeg).clamped(0, 1)
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let sz   = geo.size
                let cx   = sz.width / 2; let cy = sz.height / 2
                let center = CGPoint(x: cx, y: cy)

                Canvas { ctx, canvSz in
                    let accent = theme.primaryColor
                    let isDark = colorScheme == .dark
                    let r  = min(canvSz.width, canvSz.height) / 2 - 1.5
                    let center = CGPoint(x: canvSz.width / 2, y: canvSz.height / 2)
                    let cs = Angle.degrees(Self.startDeg - 90)
                    let ce = Angle.degrees(Self.startDeg + Self.sweepDeg - 90)
                    let cc = Angle.degrees(indicatorDeg - 90)

                    var ghost = Path()
                    ghost.addArc(center: center, radius: r, startAngle: cs, endAngle: ce, clockwise: false)
                    ctx.stroke(ghost, with: .color(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.15)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    if fraction > 0.005 {
                        var active = Path()
                        active.addArc(center: center, radius: r, startAngle: cs, endAngle: cc, clockwise: false)
                        ctx.stroke(active, with: .color(accent),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }

                    let rad  = (indicatorDeg - 90) * .pi / 180
                    let dotX = center.x + r * CGFloat(cos(rad))
                    let dotY = center.y + r * CGFloat(sin(rad))
                    let dotR: CGFloat = isHovered || dragging ? 3.5 : 2.5
                    ctx.fill(Path(ellipseIn: CGRect(x: dotX-dotR, y: dotY-dotR,
                                                    width: dotR*2, height: dotR*2)),
                             with: .color(accent))

                    if isHovered || dragging {
                        let lbl = freq >= 1000
                            ? String(format: "%.1fk", freq/1000)
                            : String(format: "%.0f", freq)
                        ctx.draw(Text(lbl).font(.system(size: 6, weight: .semibold))
                                          .foregroundColor(isDark ? .white : .black),
                                 at: center, anchor: .center)
                    }
                }
                .frame(width: 28, height: 28)
                .position(x: cx, y: cy)
                .contentShape(Circle())
                // Circular drag — coordinateSpace: .local gives coords in the 28×28 canvas frame
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        let dialCenter = CGPoint(x: 14, y: 14)
                        if !dragging {
                            dragging = true
                            dragStartAngle = angleDeg(from: drag.startLocation, center: dialCenter)
                            dragStartFreq  = freq
                        }
                        let currentAngle = angleDeg(from: drag.location, center: dialCenter)
                        var deltaAngle = currentAngle - dragStartAngle
                        if deltaAngle >  180 { deltaAngle -= 360 }
                        if deltaAngle < -180 { deltaAngle += 360 }
                        let deltaFrac = deltaAngle / Self.sweepDeg
                        let startFrac = ((dragStartFreq - range.min) / max(1, range.max - range.min)).clamped(0, 1)
                        let newFrac   = (startFrac + deltaFrac).clamped(0, 1)
                        freq = (range.min + newFrac * (range.max - range.min)).clamped(range.min, range.max)
                    }
                    .onEnded { _ in dragging = false }
                )
                .onHover { isHovered = $0 }
            }
            .frame(width: 28, height: 28)

            Text(freqLabel)
                .font(.system(size: 7))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .help(fxDialTooltip)
    }
}

// MARK: - EQPanelView wrapper (holds @State binding required by EQPanelView)

private struct FXAppEQWrapper: View {
    let initialSettings: EQSettings
    let onSettingsChanged: (EQSettings) -> Void
    @State private var localSettings: EQSettings

    init(initialSettings: EQSettings, onSettingsChanged: @escaping (EQSettings) -> Void) {
        self.initialSettings = initialSettings
        self.onSettingsChanged = onSettingsChanged
        _localSettings = State(initialValue: initialSettings)
    }

    var body: some View {
        EQPanelView(
            settings: $localSettings,
            onPresetSelected: { preset in
                localSettings = preset.settings
                onSettingsChanged(localSettings)
            },
            onSettingsChanged: { newSettings in
                localSettings = newSettings
                onSettingsChanged(newSettings)
            }
        )
        .onChange(of: initialSettings) { _, v in localSettings = v }
    }
}


private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(hi, max(lo, self)) }
}
