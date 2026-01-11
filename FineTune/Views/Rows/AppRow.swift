// FineTune/Views/Rows/AppRow.swift
import SwiftUI
import Combine

/// A row displaying an app with volume controls and VU meter
/// Used in the Apps section
struct AppRow: View {
    let app: AudioApp
    let volume: Float  // Linear gain 0-2
    let audioLevel: Float
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let isMutedExternal: Bool  // Mute state from AudioEngine
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var sliderValue: Double  // 0-1, log-mapped position
    @State private var isEditing = false

    /// Show muted icon when explicitly muted OR volume is 0
    private var showMutedIcon: Bool { isMutedExternal || sliderValue == 0 }

    /// Default volume to restore when unmuting from 0 (50% = unity gain)
    private let defaultUnmuteVolume: Double = 0.5

    init(
        app: AudioApp,
        volume: Float,
        audioLevel: Float = 0,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        isMuted: Bool = false,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        eqSettings: EQSettings = EQSettings(),
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {}
    ) {
        self.app = app
        self.volume = volume
        self.audioLevel = audioLevel
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.isMutedExternal = isMuted
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.eqSettings = eqSettings
        self.onEQChange = onEQChange
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        // Convert linear gain to slider position
        self._sliderValue = State(initialValue: VolumeMapping.gainToSlider(volume))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row content
            HStack(spacing: DesignTokens.Spacing.sm) {
                // App icon
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)

                // App name - expands to fill available space
                Text(app.name)
                    .font(DesignTokens.Typography.rowName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Controls section - fixed width so sliders align across rows
                HStack(spacing: DesignTokens.Spacing.sm) {
                    // Mute button
                    MuteButton(isMuted: showMutedIcon) {
                        if showMutedIcon {
                            // Unmute: restore to default if at 0
                            if sliderValue == 0 {
                                sliderValue = defaultUnmuteVolume
                            }
                            onMuteChange(false)
                        } else {
                            // Mute
                            onMuteChange(true)
                        }
                    }

                    // EQ button
                    Button {
                        onEQToggle()
                    } label: {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 12))
                            .foregroundColor(isEQExpanded ? .accentColor : (eqSettings.isEnabled ? .accentColor.opacity(0.7) : .secondary))
                    }
                    .buttonStyle(.plain)
                    .help("Equalizer")

                    // Volume slider with unity marker
                    MinimalSlider(
                        value: $sliderValue,
                        showUnityMarker: true,
                        onEditingChanged: { editing in
                            isEditing = editing
                        }
                    )
                    .frame(width: DesignTokens.Dimensions.sliderWidth)
                    .opacity(showMutedIcon ? 0.5 : 1.0)
                    .onChange(of: sliderValue) { _, newValue in
                        let gain = VolumeMapping.sliderToGain(newValue)
                        onVolumeChange(gain)
                        // Auto-unmute when slider moved while muted
                        if isMutedExternal {
                            onMuteChange(false)
                        }
                    }

                    // Volume percentage (0-200% matching slider position)
                    Text("\(Int(sliderValue * 200))%")
                        .percentageStyle()

                    // VU Meter (shows gray bars when muted or volume is 0)
                    VUMeter(level: audioLevel, isMuted: showMutedIcon)

                    // Device picker - takes remaining space in controls
                    DevicePicker(
                        devices: devices,
                        selectedDeviceUID: selectedDeviceUID,
                        onDeviceSelected: onDeviceSelected
                    )
                }
                .frame(width: DesignTokens.Dimensions.controlsWidth)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)

            // Expandable EQ panel
            if isEQExpanded {
                EQPanelView(
                    settings: Binding(
                        get: { eqSettings },
                        set: { onEQChange($0) }
                    ),
                    onPresetSelected: { preset in
                        onEQChange(preset.settings)
                    },
                    onSettingsChanged: { settings in
                        onEQChange(settings)
                    }
                )
                .padding(.top, DesignTokens.Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .hoverableRow()
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            sliderValue = VolumeMapping.gainToSlider(newValue)
        }
    }
}

// MARK: - App Row with Timer-based Level Updates

/// App row that polls audio levels at regular intervals
struct AppRowWithLevelPolling: View {
    let app: AudioApp
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let getAudioLevel: () -> Float
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var displayLevel: Float = 0
    @State private var levelTimer: Timer?

    init(
        app: AudioApp,
        volume: Float,
        isMuted: Bool,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        getAudioLevel: @escaping () -> Float,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        eqSettings: EQSettings = EQSettings(),
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {}
    ) {
        self.app = app
        self.volume = volume
        self.isMuted = isMuted
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.getAudioLevel = getAudioLevel
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.eqSettings = eqSettings
        self.onEQChange = onEQChange
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
    }

    var body: some View {
        AppRow(
            app: app,
            volume: volume,
            audioLevel: displayLevel,
            devices: devices,
            selectedDeviceUID: selectedDeviceUID,
            isMuted: isMuted,
            onVolumeChange: onVolumeChange,
            onMuteChange: onMuteChange,
            onDeviceSelected: onDeviceSelected,
            eqSettings: eqSettings,
            onEQChange: onEQChange,
            isEQExpanded: isEQExpanded,
            onEQToggle: onEQToggle
        )
        .onAppear {
            startLevelPolling()
        }
        .onDisappear {
            stopLevelPolling()
        }
    }

    private func startLevelPolling() {
        levelTimer = Timer.scheduledTimer(
            withTimeInterval: DesignTokens.Timing.vuMeterUpdateInterval,
            repeats: true
        ) { _ in
            displayLevel = getAudioLevel()
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}

// MARK: - Previews

#Preview("App Row") {
    PreviewContainer {
        VStack(spacing: 4) {
            AppRow(
                app: MockData.sampleApps[0],
                volume: 1.0,
                audioLevel: 0.65,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[0].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )

            AppRow(
                app: MockData.sampleApps[1],
                volume: 0.5,
                audioLevel: 0.25,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[1].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )

            AppRow(
                app: MockData.sampleApps[2],
                volume: 1.5,
                audioLevel: 0.85,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[2].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )
        }
    }
}

#Preview("App Row - Multiple Apps") {
    PreviewContainer {
        VStack(spacing: 4) {
            ForEach(MockData.sampleApps) { app in
                AppRow(
                    app: app,
                    volume: Float.random(in: 0.5...1.5),
                    audioLevel: Float.random(in: 0...0.8),
                    devices: MockData.sampleDevices,
                    selectedDeviceUID: MockData.sampleDevices.randomElement()!.uid,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in }
                )
            }
        }
    }
}
