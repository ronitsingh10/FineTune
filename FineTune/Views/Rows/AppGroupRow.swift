// FineTune/Views/Rows/AppGroupRow.swift
import SwiftUI
import AppKit

/// Menu bar row for an audio group: shared volume, mute, boost, routing, and EQ.
struct AppGroupRow: View {
    let group: AppGroup
    let liveMembers: [AudioApp]
    let inactiveMembers: [AppGroupMemberInfo]
    let devices: [AudioDevice]
    let deviceIconOverrides: [String: String]
    let defaultDeviceUID: String?
    let userPresets: [UserEQPreset]
    let isEQExpanded: Bool
    let isFocused: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onBoostChange: (BoostLevel) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onEQChange: (EQSettings) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let onEQToggle: () -> Void
    let onToggleCollapsed: () -> Void
    /// Peak level across live members; polled while the popup is visible.
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    var onRemoveMember: ((String) -> Void)? = nil
    var showsRemoveControls: Bool = false

    @State private var localEQSettings: EQSettings
    @State private var displayLevel: Float = 0
    @State private var levelTimer: Timer?

    init(
        group: AppGroup,
        liveMembers: [AudioApp],
        inactiveMembers: [AppGroupMemberInfo],
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        defaultDeviceUID: String? = nil,
        userPresets: [UserEQPreset] = [],
        isEQExpanded: Bool = false,
        isFocused: Bool = false,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        onDeviceSelected: @escaping (String) -> Void = { _ in },
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onEQChange: @escaping (EQSettings) -> Void,
        onUserPresetSelected: @escaping (UserEQPreset) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        onEQToggle: @escaping () -> Void = {},
        onToggleCollapsed: @escaping () -> Void = {},
        getAudioLevel: @escaping () -> Float = { 0 },
        isPopupVisible: Bool = true,
        onRemoveMember: ((String) -> Void)? = nil,
        showsRemoveControls: Bool = false
    ) {
        self.group = group
        self.liveMembers = liveMembers
        self.inactiveMembers = inactiveMembers
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.defaultDeviceUID = defaultDeviceUID
        self.userPresets = userPresets
        self.isEQExpanded = isEQExpanded
        self.isFocused = isFocused
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onBoostChange = onBoostChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onEQChange = onEQChange
        self.onUserPresetSelected = onUserPresetSelected
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.onEQToggle = onEQToggle
        self.onToggleCollapsed = onToggleCollapsed
        self.getAudioLevel = getAudioLevel
        self.isPopupVisible = isPopupVisible
        self.onRemoveMember = onRemoveMember
        self.showsRemoveControls = showsRemoveControls
        self._localEQSettings = State(initialValue: group.eqSettings)
    }

    private var selectedDeviceUID: String {
        if group.followsDefault {
            return defaultDeviceUID ?? ""
        }
        return group.deviceUID ?? defaultDeviceUID ?? ""
    }

    private var memberIcons: [NSImage] {
        let liveIcons = liveMembers.map(\.icon)
        let inactiveIcons = inactiveMembers.map { DisplayableApp.loadIcon(bundleID: $0.bundleID) }
        return Array((liveIcons + inactiveIcons).prefix(3))
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded, isFocused: isFocused) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    VUMeter(
                        level: displayLevel,
                        isMuted: group.muted || group.volume == 0
                    )

                    Button(action: onToggleCollapsed) {
                        Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .help(group.isCollapsed ? "Show members" : "Hide members")

                    stackedIcons

                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                        if let subtitle = routingOrMemberSubtitle {
                            Text(subtitle)
                                .font(.system(size: 9))
                                .foregroundStyle(DesignTokens.Colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    AppRowControls(
                        volume: group.volume,
                        isMuted: group.muted,
                        devices: devices,
                        deviceIconOverrides: deviceIconOverrides,
                        selectedDeviceUID: selectedDeviceUID,
                        selectedDeviceUIDs: Set(group.selectedDeviceUIDs),
                        isFollowingDefault: group.followsDefault,
                        defaultDeviceUID: defaultDeviceUID,
                        deviceSelectionMode: group.deviceSelectionMode,
                        boost: group.boost,
                        isEQExpanded: isEQExpanded,
                        onVolumeChange: onVolumeChange,
                        onMuteChange: onMuteChange,
                        onBoostChange: onBoostChange,
                        onDeviceSelected: onDeviceSelected,
                        onDevicesSelected: onDevicesSelected,
                        onDeviceModeChange: onDeviceModeChange,
                        onSelectFollowDefault: onSelectFollowDefault,
                        onEQToggle: onEQToggle,
                        isRowFocused: isFocused
                    )
                }
                .frame(height: DesignTokens.Dimensions.rowContentHeight)

                if !group.isCollapsed {
                    memberList
                        .padding(.top, DesignTokens.Spacing.xs)
                }
            }
        } expandedContent: {
            EQPanelView(
                settings: $localEQSettings,
                userPresets: userPresets,
                onPresetSelected: { preset in
                    localEQSettings = preset.settings
                    onEQChange(preset.settings)
                },
                onUserPresetSelected: { userPreset in
                    localEQSettings = userPreset.settings
                    onUserPresetSelected(userPreset)
                },
                onSettingsChanged: { settings in
                    onEQChange(settings)
                },
                onSavePreset: onSavePreset,
                onDeleteUserPreset: onDeleteUserPreset,
                onRenameUserPreset: onRenameUserPreset
            )
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .onChange(of: group.eqSettings) { _, newValue in
            localEQSettings = newValue
        }
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
                displayLevel = 0
            }
        }
    }

    private func startLevelPolling() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(
            withTimeInterval: DesignTokens.Timing.vuMeterUpdateInterval,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated {
                displayLevel = getAudioLevel()
            }
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private var routingOrMemberSubtitle: String? {
        if let routing = DevicePicker.routingSubtitle(
            devices: devices,
            selectedDeviceUID: selectedDeviceUID,
            selectedDeviceUIDs: Set(group.selectedDeviceUIDs),
            isFollowingDefault: group.followsDefault,
            mode: group.deviceSelectionMode
        ) {
            return routing
        }
        let count = liveMembers.count + inactiveMembers.count
        let playing = liveMembers.count
        if playing > 0 {
            return "\(count) apps · \(playing) playing"
        }
        return "\(count) apps"
    }

    private var stackedIcons: some View {
        ZStack(alignment: .leading) {
            if memberIcons.isEmpty {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: DesignTokens.Dimensions.rowContentHeight - 4,
                           height: DesignTokens.Dimensions.rowContentHeight - 4)
            } else {
                ForEach(Array(memberIcons.enumerated()), id: \.offset) { index, icon in
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(DesignTokens.Colors.hoverSurface))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .offset(x: CGFloat(index) * 10)
                }
            }
        }
        .frame(width: memberIcons.isEmpty ? 24 : CGFloat(min(memberIcons.count, 3) - 1) * 10 + 18,
               height: DesignTokens.Dimensions.rowContentHeight - 4,
               alignment: .leading)
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(liveMembers, id: \.persistenceIdentifier) { app in
                memberRow(
                    icon: app.icon,
                    name: app.name,
                    isPlaying: true,
                    identifier: app.persistenceIdentifier
                )
            }
            ForEach(inactiveMembers) { info in
                memberRow(
                    icon: DisplayableApp.loadIcon(bundleID: info.bundleID),
                    name: info.displayName,
                    isPlaying: false,
                    identifier: info.persistenceIdentifier
                )
            }
        }
        .padding(.leading, 28)
    }

    private func memberRow(icon: NSImage, name: String, isPlaying: Bool, identifier: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .opacity(isPlaying ? 1.0 : 0.45)

            Text(name)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(isPlaying ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if !isPlaying {
                Text("Idle")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            if showsRemoveControls, let onRemoveMember {
                Button {
                    onRemoveMember(identifier)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove from group")
            }
        }
        .frame(height: 20)
    }
}
