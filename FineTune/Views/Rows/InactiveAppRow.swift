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
    let volume: Float  // Linear gain 0-maxVolumeBoost
    let devices: [AudioDevice]
    let selectedDeviceUID: String?
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let isMuted: Bool
    let maxVolumeBoost: Float
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onUnpin: () -> Void  // Inactive apps can only be unpinned
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var isPinButtonHovered = false
    @State private var localEQSettings: EQSettings

    /// Pin button color - always visible for inactive (pinned) apps
    private var pinButtonColor: Color {
        if isPinButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveActive  // Always active (pinned)
        }
    }

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
        maxVolumeBoost: Float = 2.0,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onUnpin: @escaping () -> Void,
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
        self.maxVolumeBoost = maxVolumeBoost
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onUnpin = onUnpin
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
                // Unpin star button - left of app icon
                Button {
                    onUnpin()
                } label: {
                    Image(systemName: "star.fill")
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
                .help("Unpin app")
                .animation(DesignTokens.Animation.hover, value: pinButtonColor)
                .animation(DesignTokens.Animation.quick, value: isPinButtonHovered)

                // App icon (no activation for inactive apps - can't bring to front what isn't running)
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
                    .opacity(0.6)  // Dimmed to indicate inactive state

                // App name - expands to fill available space
                Text(appInfo.displayName)
                    .font(DesignTokens.Typography.rowName)
                    .lineLimit(1)
                    .help(appInfo.displayName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)  // Dimmed text

                // Shared controls section (VU meter always 0 for inactive apps)
                AppRowControls(
                    volume: volume,
                    isMuted: isMuted,
                    audioLevel: 0,  // No audio for inactive apps
                    devices: devices,
                    selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
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
