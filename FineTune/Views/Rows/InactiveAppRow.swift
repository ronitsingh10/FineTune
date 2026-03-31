// FineTune/Views/Rows/InactiveAppRow.swift
import SwiftUI

/// A row displaying a pinned but inactive app (not currently producing audio).
/// Similar to AppRow but:
/// - Uses PinnedAppInfo instead of AudioApp
/// - VU meter always shows 0 (no audio level polling)
/// - Slightly dimmed appearance to indicate inactive state
/// - All settings (volume/mute/EQ/device) work normally and are persisted
struct InactiveAppRow: View {
    let appInfo: PinnedAppInfo
    let icon: NSImage
    let volume: Float  // Linear gain 0-1 (boost applied separately)
    let devices: [AudioDevice]
    let selectedDeviceUID: String?
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let isMuted: Bool
    let useLogScale: Bool
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var localEQSettings: EQSettings

    init(
        appInfo: PinnedAppInfo,
        icon: NSImage,
        volume: Float,
        devices: [AudioDevice],
        selectedDeviceUID: String?,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        isMuted: Bool = false,
        useLogScale: Bool = false,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        eqSettings: EQSettings = EQSettings(),
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {}
    ) {
        self.appInfo = appInfo
        self.icon = icon
        self.volume = volume
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.isMuted = isMuted
        self.useLogScale = useLogScale
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.eqSettings = eqSettings
        self.onEQChange = onEQChange
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self._localEQSettings = State(initialValue: eqSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            // Header: Main row content (always visible)
            HStack(spacing: DesignTokens.Spacing.sm) {
                // VU Meter (always 0 for inactive apps)
                VUMeter(level: 0, isMuted: isMuted)

                // App icon (no activation for inactive apps)
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Dimensions.rowContentHeight - 4, height: DesignTokens.Dimensions.rowContentHeight - 4)

                // App name - expands to fill available space
                Text(appInfo.displayName)
                    .font(DesignTokens.Typography.rowName)
                    .lineLimit(1)
                    .help(appInfo.displayName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                // Shared controls section (VU meter always 0 for inactive apps)
                AppRowControls(
                    volume: volume,
                    isMuted: isMuted,
                    useLogScale: useLogScale,
                    devices: devices,
                    selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
                    selectedDeviceUIDs: selectedDeviceUIDs,
                    isFollowingDefault: isFollowingDefault,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: deviceSelectionMode,
                    boost: boost,
                    isEQExpanded: isEQExpanded,
                    onVolumeChange: onVolumeChange,
                    onMuteChange: onMuteChange,
                    onBoostChange: onBoostChange,
                    onDeviceSelected: onDeviceSelected,
                    onDevicesSelected: onDevicesSelected,
                    onDeviceModeChange: onDeviceModeChange,
                    onSelectFollowDefault: onSelectFollowDefault,
                    onEQToggle: onEQToggle
                )
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
            .opacity(0.6)
        } expandedContent: {
            // EQ panel
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
            localEQSettings = newValue
        }
    }
}
