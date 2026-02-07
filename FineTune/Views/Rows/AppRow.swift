// FineTune/Views/Rows/AppRow.swift
import SwiftUI
import Combine

/// A row displaying an app with volume controls and VU meter
/// Used in the Apps section
struct AppRow: View {
    let app: AudioApp
    let volume: Float  // Linear gain 0-maxVolumeBoost
    let audioLevel: Float
    let devices: [AudioDevice]
    let selectedDeviceUID: String  // For single mode
    let selectedDeviceUIDs: Set<String>  // For multi mode
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let isMutedExternal: Bool  // Mute state from AudioEngine
    let maxVolumeBoost: Float  // Maximum volume multiplier (e.g., 2.0 = 200%, 4.0 = 400%)
    let isPinned: Bool  // Whether app is pinned to top
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void  // Single mode
    let onDevicesSelected: (Set<String>) -> Void  // Multi mode
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onAppActivate: () -> Void
    let onPinToggle: () -> Void  // Toggle pin state
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var isRowHovered = false
    @State private var isIconHovered = false
    @State private var isPinButtonHovered = false
    @State private var localEQSettings: EQSettings

    /// Pin button color - visible when pinned or row is hovered
    private var pinButtonColor: Color {
        if isPinned {
            return DesignTokens.Colors.interactiveActive
        } else if isPinButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else if isRowHovered {
            return DesignTokens.Colors.interactiveDefault
        } else {
            return .clear
        }
    }

    init(
        app: AudioApp,
        volume: Float,
        audioLevel: Float = 0,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        isMuted: Bool = false,
        maxVolumeBoost: Float = 2.0,
        isPinned: Bool = false,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onAppActivate: @escaping () -> Void = {},
        onPinToggle: @escaping () -> Void = {},
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
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.isMutedExternal = isMuted
        self.maxVolumeBoost = maxVolumeBoost
        self.isPinned = isPinned
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onAppActivate = onAppActivate
        self.onPinToggle = onPinToggle
        self.eqSettings = eqSettings
        self.onEQChange = onEQChange
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        // Initialize local EQ state for reactive UI updates
        self._localEQSettings = State(initialValue: eqSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            // Header: Main row content (always visible)
            HStack(spacing: DesignTokens.Spacing.sm) {
                // Pin/unpin star button - left of app icon
                Button {
                    onPinToggle()
                } label: {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(pinButtonColor)
                        .frame(
                            minWidth: DesignTokens.Dimensions.minTouchTarget,
                            minHeight: DesignTokens.Dimensions.minTouchTarget
                        )
                        .contentShape(Rectangle())
                        .scaleEffect(isPinButtonHovered ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { isPinButtonHovered = $0 }
                .help(isPinned ? "Unpin app" : "Pin app to top")
                .animation(DesignTokens.Animation.hover, value: pinButtonColor)
                .animation(DesignTokens.Animation.quick, value: isPinButtonHovered)

                // App icon - clickable to activate app
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
                    .opacity(isIconHovered ? 0.7 : 1.0)
                    .onHover { hovering in
                        isIconHovered = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onTapGesture {
                        onAppActivate()
                    }

                // App name - expands to fill available space
                Text(app.name)
                    .font(DesignTokens.Typography.rowName)
                    .lineLimit(1)
                    .help(app.name)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Shared controls section
                AppRowControls(
                    volume: volume,
                    isMuted: isMutedExternal,
                    audioLevel: audioLevel,
                    devices: devices,
                    selectedDeviceUID: selectedDeviceUID,
                    selectedDeviceUIDs: selectedDeviceUIDs,
                    isFollowingDefault: isFollowingDefault,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: deviceSelectionMode,
                    maxVolumeBoost: maxVolumeBoost,
                    isEQExpanded: isEQExpanded,
                    onVolumeChange: onVolumeChange,
                    onMuteChange: onMuteChange,
                    onDeviceSelected: onDeviceSelected,
                    onDevicesSelected: onDevicesSelected,
                    onDeviceModeChange: onDeviceModeChange,
                    onSelectFollowDefault: onSelectFollowDefault,
                    onEQToggle: onEQToggle
                )
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
            .onHover { isRowHovered = $0 }
        } expandedContent: {
            // EQ panel - shown when expanded
            // SwiftUI calculates natural height via conditional rendering
            EQPanelView(
                settings: $localEQSettings,
                onPresetSelected: { preset in
                    localEQSettings = preset.settings
                    onEQChange(preset.settings)
                },
                onSettingsChanged: { settings in
                    onEQChange(settings)
                }
            )
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .onChange(of: eqSettings) { _, newValue in
            // Sync from parent when external EQ settings change
            localEQSettings = newValue
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
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let maxVolumeBoost: Float
    let isPinned: Bool  // Whether app is pinned to top
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onAppActivate: () -> Void
    let onPinToggle: () -> Void  // Toggle pin state
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
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        maxVolumeBoost: Float = 2.0,
        isPinned: Bool = false,
        getAudioLevel: @escaping () -> Float,
        isPopupVisible: Bool = true,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onAppActivate: @escaping () -> Void = {},
        onPinToggle: @escaping () -> Void = {},
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
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.maxVolumeBoost = maxVolumeBoost
        self.isPinned = isPinned
        self.getAudioLevel = getAudioLevel
        self.isPopupVisible = isPopupVisible
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onAppActivate = onAppActivate
        self.onPinToggle = onPinToggle
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
            selectedDeviceUIDs: selectedDeviceUIDs,
            isFollowingDefault: isFollowingDefault,
            defaultDeviceUID: defaultDeviceUID,
            deviceSelectionMode: deviceSelectionMode,
            isMuted: isMuted,
            maxVolumeBoost: maxVolumeBoost,
            isPinned: isPinned,
            onVolumeChange: onVolumeChange,
            onMuteChange: onMuteChange,
            onDeviceSelected: onDeviceSelected,
            onDevicesSelected: onDevicesSelected,
            onDeviceModeChange: onDeviceModeChange,
            onSelectFollowDefault: onSelectFollowDefault,
            onAppActivate: onAppActivate,
            onPinToggle: onPinToggle,
            eqSettings: eqSettings,
            onEQChange: onEQChange,
            isEQExpanded: isEQExpanded,
            onEQToggle: onEQToggle
        )
        .onAppear {
            if isPopupVisible {
                startLevelPolling()
            }
        }
        .onDisappear {
            stopLevelPolling()
        }
        .onChange(of: isPopupVisible) { _, visible in
            if visible {
                startLevelPolling()
            } else {
                stopLevelPolling()
                displayLevel = 0  // Reset meter when hidden
            }
        }
    }

    private func startLevelPolling() {
        // Guard against duplicate timers
        guard levelTimer == nil else { return }

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
