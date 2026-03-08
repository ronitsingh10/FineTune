// FineTune/Views/FXPanelView.swift
import SwiftUI

// MARK: - FXPanelView (top-level, owns SOUNDS System/Apps toggle)

struct FXPanelView: View {
    let settings: FXSettings
    let onSettingsChanged: (FXSettings) -> Void

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
         displayableApps: [DisplayableApp],
         expandedEQAppID: String?,
         onEQToggle: @escaping (String) -> Void,
         audioEngine: AudioEngine) {
        self.settings = settings
        self.onSettingsChanged = onSettingsChanged
        self.displayableApps = displayableApps
        self.expandedEQAppID = expandedEQAppID
        self.onEQToggle = onEQToggle
        self.audioEngine = audioEngine
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
                FXSystemPanel(settings: settings, onSettingsChanged: onSettingsChanged)
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

    private let buttonSize: CGFloat = 26
    private let cornerRadius: CGFloat = 6   // matches DesignTokens.Dimensions.buttonRadius

    var body: some View {
        HStack(spacing: 2) {
            tab("System", target: .system)
            tab("Apps",   target: .apps)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius + 3)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius + 3)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
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
                .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.6))
                .frame(height: buttonSize)
                .padding(.horizontal, 8)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.white.opacity(0.1))
                            .matchedGeometryEffect(id: "soundTarget", in: ns)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FX System Panel (preset + sliders + EQ — all in glass cells)

private struct FXSystemPanel: View {
    let settings: FXSettings
    let onSettingsChanged: (FXSettings) -> Void

    @State private var local: FXSettings
    @State private var selectedPreset: FXPreset? = .general
    @State private var isDirty: Bool = false
    @State private var fxAreaHovered = false

    init(settings: FXSettings, onSettingsChanged: @escaping (FXSettings) -> Void) {
        self.settings = settings
        self.onSettingsChanged = onSettingsChanged
        _local = State(initialValue: settings)
        if let match = settings.matchingPreset() {
            _selectedPreset = State(initialValue: match)
        } else {
            _selectedPreset = State(initialValue: .general)
            _isDirty = State(initialValue: true)
        }
    }

    private var presetLabel: String {
        guard let p = selectedPreset else { return "General" }
        return isDirty ? "\(p.name) *" : p.name
    }

    var body: some View {
        VStack(spacing: 8) {
            // ── Cell 1: Preset + Enable ──────────────────────────────────
            ExpandableGlassRow(isExpanded: false) {
                HStack(spacing: 8) {
                    FXPresetDropdown(label: presetLabel) { preset in
                        selectedPreset = preset
                        isDirty = false
                        local = preset.settings
                        onSettingsChanged(local)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { local.isEnabled },
                        set: { local.isEnabled = $0; onSettingsChanged(local) }
                    ))
                    .toggleStyle(.switch)
                    .scaleEffect(0.7)
                    .labelsHidden()
                    .frame(width: 36)
                    Text("Enable")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(.primary)
                }
                .frame(height: DesignTokens.Dimensions.rowContentHeight)
            } expandedContent: { EmptyView() }

            // ── Cell 2: FX Sliders ───────────────────────────────────────
            ExpandableGlassRow(isExpanded: false) {
                VStack(alignment: .leading, spacing: 6) {
                    fxSlider("Clarity",        kp: \.clarity,       set: { local.clarity = $0 })
                    fxSlider("Ambience",       kp: \.ambience,      set: { local.ambience = $0 })
                    fxSlider("Surround Sound", kp: \.surroundSound, set: { local.surroundSound = $0 })
                    fxSlider("Dynamic Boost",  kp: \.dynamicBoost,  set: { local.dynamicBoost = $0 })
                    fxSlider("Bass Boost",     kp: \.bassBoost,     set: { local.bassBoost = $0 })
                }
                .padding(.vertical, 4)
                .onHover { fxAreaHovered = $0 }
            } expandedContent: { EmptyView() }
            .opacity(local.isEnabled ? 1 : 0.4)
            .disabled(!local.isEnabled)

            // ── Cell 3: EQ Curve + Dials ─────────────────────────────────
            ExpandableGlassRow(isExpanded: false) {
                VStack(spacing: 0) {
                    FXEQCurve(gains: Binding(
                        get: { local.eqGains },
                        set: { local.eqGains = $0; markDirtyAndEmit() }
                    ))
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    FXDialRow(freqs: Binding(
                        get: { local.eqFreqs },
                        set: { local.eqFreqs = $0; markDirtyAndEmit() }
                    ))
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            } expandedContent: { EmptyView() }
            .opacity(local.isEnabled ? 1 : 0.4)
            .disabled(!local.isEnabled)
        }
        .onChange(of: settings) { _, v in
            local = v
            if let m = v.matchingPreset() { selectedPreset = m; isDirty = false }
        }
    }

    @ViewBuilder
    private func fxSlider(_ label: String, kp: KeyPath<FXSettings, Int>,
                           set: @escaping (Int) -> Void) -> some View {
        FXSliderRow(
            label: label,
            value: Binding(get: { local[keyPath: kp] }, set: { set($0); markDirtyAndEmit() }),
            showValue: fxAreaHovered
        )
    }

    private func markDirtyAndEmit() {
        isDirty = true
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
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 200)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - FX Slider row
// Label above, then the track with the value overlaid just right of the thumb.

private struct FXSliderRow: View {
    let label: String
    @Binding var value: Int
    let showValue: Bool
    private let accent = Color(red: 0.9, green: 0.2, blue: 0.3)
    private let steps  = 10
    private let thumbR: CGFloat = 7
    private let valueGap: CGFloat = 6   // gap between thumb edge and value text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            GeometryReader { geo in
                let w     = geo.size.width
                let frac  = CGFloat(value) / CGFloat(steps)
                let thumbX = (thumbR + frac * (w - thumbR * 2)).clamped(thumbR, w - thumbR)
                // Value text sits just right of the thumb.
                // At max (10) we flip it left of the thumb so it never overflows.
                let atMax = value == steps
                let labelX = atMax
                    ? thumbX - thumbR - valueGap   // anchor .trailing when at max
                    : thumbX + thumbR + valueGap   // anchor .leading otherwise

                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 3)

                    // Filled portion
                    Capsule()
                        .fill(accent)
                        .frame(width: thumbX, height: 3)

                    // Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbR * 2, height: thumbR * 2)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .offset(x: thumbX - thumbR)

                    // Value — follows thumb. At max, sits left of thumb so it's never hidden.
                    if showValue {
                        let halfLabel: CGFloat = 8   // approx half-width of "10"
                        let labelCx = atMax
                            ? thumbX - thumbR - valueGap - halfLabel  // left of thumb
                            : thumbX + thumbR + valueGap + halfLabel  // right of thumb
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
                    let raw = drag.location.x / w * CGFloat(steps)
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

    private let labelH: CGFloat = 13
    private let accent = Color(red: 0.9, green: 0.2, blue: 0.3)
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
            let colW = size.width / CGFloat(n)

            Canvas { ctx, sz in
                let midY = labelH + (sz.height - labelH) * 0.5

                // Grid verticals
                for i in 0..<n {
                    let x = colCenter(i, width: sz.width)
                    var p = Path(); p.move(to: CGPoint(x: x, y: labelH))
                    p.addLine(to: CGPoint(x: x, y: sz.height))
                    ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                }
                // Midline
                var mid = Path()
                mid.move(to: CGPoint(x: 0, y: midY))
                mid.addLine(to: CGPoint(x: sz.width, y: midY))
                ctx.stroke(mid, with: .color(.white.opacity(0.15)), lineWidth: 0.5)

                let pts = (0..<n).map { i in
                    CGPoint(x: colCenter(i, width: sz.width), y: yFor(gains[i], height: sz.height))
                }

                // Fill — edges go straight down from first/last dot, not to midline
                var fill = Path()
                fill.move(to: CGPoint(x: pts[0].x, y: sz.height))
                fill.addLine(to: pts[0])
                for i in 1..<n {
                    let ctrl = colW * 0.4
                    fill.addCurve(to: pts[i],
                        control1: CGPoint(x: pts[i-1].x + ctrl, y: pts[i-1].y),
                        control2: CGPoint(x: pts[i].x   - ctrl, y: pts[i].y))
                }
                fill.addLine(to: CGPoint(x: pts[n-1].x, y: sz.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(accent.opacity(0.18)))

                // Curve line
                var line = Path()
                line.move(to: pts[0])
                for i in 1..<n {
                    let ctrl = colW * 0.4
                    line.addCurve(to: pts[i],
                        control1: CGPoint(x: pts[i-1].x + ctrl, y: pts[i-1].y),
                        control2: CGPoint(x: pts[i].x   - ctrl, y: pts[i].y))
                }
                ctx.stroke(line, with: .color(accent),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

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
                                .foregroundColor(isDrag ? .white : Color.white.opacity(0.65)),
                            at: CGPoint(x: p.x, y: p.y - 10), anchor: .center
                        )
                    }
                }
            }
            .background(Color.black.opacity(0.25))
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
            .onHover { isHovering = $0 }
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
                        range: fxEQBandRanges[i]
                    )
                    .frame(width: colW)
                }
            }
        }
        .frame(height: 52)
    }
}

// MARK: - Frequency Dial

private struct FXFreqDial: View {
    @Binding var freq: Double
    let range: (min: Double, max: Double)

    @State private var isHovered = false
    @State private var dragging  = false
    @State private var startY: CGFloat   = 0
    @State private var startFreq: Double = 0

    private static let startDeg: Double = 225.0
    private static let sweepDeg: Double = 270.0
    private let accent = Color(red: 0.9, green: 0.2, blue: 0.3)

    private var fraction: Double {
        ((freq - range.min) / max(1, range.max - range.min)).clamped(0, 1)
    }
    private var indicatorDeg: Double { Self.startDeg + fraction * Self.sweepDeg }

    private var freqLabel: String {
        freq >= 1000
            ? String(format: "%.2f kHz", freq / 1000)
            : String(format: "%.0f Hz", freq)
    }

    var body: some View {
        VStack(spacing: 2) {
            Canvas { ctx, size in
                let cx = size.width/2, cy = size.height/2
                let r  = min(cx, cy) - 1.5
                let center = CGPoint(x: cx, y: cy)
                let cs = Angle.degrees(Self.startDeg - 90)
                let ce = Angle.degrees(Self.startDeg + Self.sweepDeg - 90)
                let cc = Angle.degrees(indicatorDeg - 90)

                var ghost = Path()
                ghost.addArc(center: center, radius: r, startAngle: cs, endAngle: ce, clockwise: false)
                ctx.stroke(ghost, with: .color(.white.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))

                if fraction > 0.005 {
                    var active = Path()
                    active.addArc(center: center, radius: r, startAngle: cs, endAngle: cc, clockwise: false)
                    ctx.stroke(active, with: .color(accent),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }

                let rad = (indicatorDeg - 90) * .pi / 180
                let dotX = cx + r * CGFloat(cos(rad))
                let dotY = cy + r * CGFloat(sin(rad))
                let dotR: CGFloat = isHovered || dragging ? 3.5 : 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: dotX-dotR, y: dotY-dotR,
                                                width: dotR*2, height: dotR*2)),
                         with: .color(accent))

                if isHovered || dragging {
                    let lbl = freq >= 1000
                        ? String(format: "%.1fk", freq/1000)
                        : String(format: "%.0f", freq)
                    ctx.draw(Text(lbl).font(.system(size: 6, weight: .semibold)).foregroundColor(.white),
                             at: center, anchor: .center)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging { dragging = true; startY = drag.startLocation.y; startFreq = freq }
                    freq = (startFreq + Double(startY - drag.location.y) * (range.max - range.min) / 120)
                        .clamped(range.min, range.max)
                }
                .onEnded { _ in dragging = false }
            )
            .onHover { isHovered = $0 }

            Text(freqLabel)
                .font(.system(size: 7))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
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
