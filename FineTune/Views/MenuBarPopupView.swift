// FineTune/Views/MenuBarPopupView.swift
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @ObservedObject var updateManager: UpdateManager

    /// Icon style that was applied at app launch (for restart-required detection)
    let launchIconStyle: MenuBarIconStyle

    let permission: AudioRecordingPermission

    /// Memoized sorted output devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Memoized sorted input devices
    @State private var sortedInputDevices: [AudioDevice] = []

    /// Which device tab is selected (false = output, true = input)
    @State private var showingInputDevices = false

    /// Track which app has its EQ panel expanded (only one at a time)
    /// Uses DisplayableApp.id (String) to work with both active and inactive apps
    @State private var expandedRowID: String?

    /// Debounce EQ toggle to prevent rapid clicks during animation
    @State private var isEQAnimating = false

    /// Track popup visibility to pause VU meter polling when hidden
    @State private var isPopupVisible = true

    /// Error message shown when AutoEQ profile import fails
    @State private var autoEQImportError: String?
    /// Task that auto-clears the import error after 3 seconds
    @State private var importErrorClearTask: Task<Void, Never>?

    /// Track whether settings panel is open
    @State private var isSettingsOpen = false

    /// Debounce settings toggle to prevent rapid clicks during animation
    @State private var isSettingsAnimating = false

    /// Local copy of app settings for binding
    @State private var localAppSettings: AppSettings = AppSettings()

    /// Memoized paired Bluetooth devices
    @State private var pairedDevices: [PairedBluetoothDevice] = []

    /// Whether Bluetooth hardware is powered on
    @State private var isBluetoothOn = false

    /// Whether edit mode is active (affects both device priority and app visibility)
    @State private var isEditingDevicePriority = false

    /// Tracks which tab was active when edit mode started (for correct save on exit)
    @State private var wasEditingInputDevices = false

    /// Editable copy of device order for drag-and-drop reordering
    @State private var editableDeviceOrder: [AudioDevice] = []

    /// Hover state for support link heart animation
    @State private var isSupportHovered = false

    /// Namespace for device toggle animation
    @Namespace private var deviceToggleNamespace

    // MARK: - Scroll Thresholds

    /// Number of devices before scroll kicks in
    private let deviceScrollThreshold = 4
    /// Max height for devices scroll area
    private let deviceScrollHeight: CGFloat = 160
    /// Number of apps before scroll kicks in
    private let appScrollThreshold = 5
    /// Max height for apps scroll area
    private let appScrollHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Header row - always visible, shows tabs or Settings title
            HStack(alignment: .top) {
                if isSettingsOpen {
                    Text("Settings")
                        .sectionHeaderStyle()
                } else {
                    deviceTabsHeader
                    Spacer()
                    if isEditingDevicePriority {
                        Text("Drag or type a number to set priority")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    } else {
                        defaultDevicesStatus
                    }
                }
                Spacer()
                if !isSettingsOpen {
                    editPriorityButton
                }
                settingsButton
            }
            .padding(.bottom, DesignTokens.Spacing.xs)

            // Conditional content with slide transition
            if isSettingsOpen {
                SettingsView(
                    settings: $localAppSettings,
                    updateManager: updateManager,
                    launchIconStyle: launchIconStyle,
                    onResetAll: {
                        audioEngine.handleSettingsReset()
                        localAppSettings = audioEngine.settingsManager.appSettings
                        // Sync Core Audio: system sounds should follow default after reset
                        deviceVolumeMonitor.setSystemFollowDefault()
                    },
                    deviceVolumeMonitor: deviceVolumeMonitor,
                    outputDevices: sortedDevices
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                mainContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: DesignTokens.Dimensions.popupWidth)
        .darkGlassBackground()
        .environment(\.colorScheme, .dark)
        .onAppear {
            updateSortedDevices()
            updateSortedInputDevices()
            pairedDevices = audioEngine.bluetoothDeviceMonitor.pairedDevices
            isBluetoothOn = audioEngine.bluetoothDeviceMonitor.isBluetoothOn
            localAppSettings = audioEngine.settingsManager.appSettings
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            if isEditingDevicePriority && !wasEditingInputDevices {
                mergeDeviceChanges(from: audioEngine.outputDevices)
            }
            updateSortedDevices()
        }
        .onChange(of: audioEngine.inputDevices) { _, _ in
            if isEditingDevicePriority && wasEditingInputDevices {
                mergeDeviceChanges(from: audioEngine.inputDevices)
            }
            updateSortedInputDevices()
        }
        .onChange(of: showingInputDevices) { _, _ in
            exitEditModeSaving()
        }
        .onChange(of: localAppSettings) { oldValue, newValue in
            audioEngine.settingsManager.updateAppSettings(newValue)
            if !oldValue.lockInputDevice && newValue.lockInputDevice {
                audioEngine.handleInputLockEnabled()
            }
            if oldValue.softwareDeviceVolumeEnabled != newValue.softwareDeviceVolumeEnabled {
                audioEngine.handleSoftwareVolumeSettingChanged()
            }
            if oldValue.loudnessCompensationEnabled != newValue.loudnessCompensationEnabled {
                audioEngine.setLoudnessCompensationEnabled(newValue.loudnessCompensationEnabled)
            }
            if oldValue.loudnessEqualizationEnabled != newValue.loudnessEqualizationEnabled {
                audioEngine.setLoudnessEqualizationEnabled(newValue.loudnessEqualizationEnabled)
            }
        }
        .onChange(of: audioEngine.bluetoothDeviceMonitor.pairedDevices) { _, newValue in
            pairedDevices = newValue
        }
        .onChange(of: audioEngine.bluetoothDeviceMonitor.isBluetoothOn) { _, newValue in
            isBluetoothOn = newValue
        }
        .onChange(of: deviceVolumeMonitor.defaultDeviceID) { _, _ in
            updateSortedDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isPopupVisible = true
            audioEngine.bluetoothDeviceMonitor.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isPopupVisible = false
            exitEditModeSaving()
        }
        .background {
            // Hidden button to handle ⌘, keyboard shortcut for toggling settings
            Button("") { toggleSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
            // Hidden button to handle Escape key to dismiss popup
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    // MARK: - Edit Priority Button

    /// Edit priority button — pencil ↔ checkmark, styled to match settingsButton
    private var editPriorityButton: some View {
        Button(isEditingDevicePriority ? "Done reordering" : "Reorder devices",
               systemImage: isEditingDevicePriority ? "checkmark" : "pencil") {
            toggleDevicePriorityEdit()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: isEditingDevicePriority ? .bold : .regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEditingDevicePriority)
        .help(isEditingDevicePriority ? "Done reordering" : "Reorder devices")
    }

    // MARK: - Settings Button

    /// Settings button with gear ↔ X morphing animation
    private var settingsButton: some View {
        Button(isSettingsOpen ? "Close Settings" : "Settings",
               systemImage: isSettingsOpen ? "xmark" : "gearshape.fill") {
            toggleSettings()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: isSettingsOpen ? .bold : .regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .rotationEffect(.degrees(isSettingsOpen ? 90 : 0))
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSettingsOpen)
    }

    /// Handles Escape key: closes settings/EQ first, then dismisses the popup
    private func handleEscape() {
        if isSettingsOpen {
            toggleSettings()
        } else if isEditingDevicePriority {
            toggleDevicePriorityEdit()
        } else if expandedRowID != nil {
            // Collapse any expanded app EQ panel
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expandedRowID = nil
            }
        } else {
            NSApp.keyWindow?.resignKey()
        }
    }

    private func toggleSettings() {
        guard !isSettingsAnimating else { return }
        exitEditModeSaving()
        isSettingsAnimating = true

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isSettingsOpen.toggle()
        }

        Task {
            try? await Task.sleep(for: .seconds(0.4))
            isSettingsAnimating = false
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        // Devices section (tabbed: Output / Input)
        devicesSection

        Divider()
            .padding(.vertical, DesignTokens.Spacing.xs)

        // Apps section (active + pinned inactive + hidden in edit mode)
        appsSection

        Divider()
            .padding(.vertical, DesignTokens.Spacing.xs)

        // Footer: support link + quit
        HStack {
            Button {
                NSWorkspace.shared.open(DesignTokens.Links.support)
            } label: {
                Label("Support", systemImage: isSupportHovered ? "heart.fill" : "heart")
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(isSupportHovered ? Color(nsColor: .systemPink) : DesignTokens.Colors.textTertiary)
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isSupportHovered = hovering
                }
            }
            .accessibilityLabel("Support FineTune")
            .help("Support FineTune")

            Spacer()

            Button("Quit FineTune") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .glassButtonStyle()
        }
    }

    // MARK: - Default Devices Status

    /// Name of the current default output device
    private var defaultOutputDeviceName: String {
        guard let uid = deviceVolumeMonitor.defaultDeviceUID,
              let device = sortedDevices.first(where: { $0.uid == uid }) else {
            return "No Output"
        }
        return device.name
    }

    /// Name of the current default input device
    private var defaultInputDeviceName: String {
        guard let uid = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
            return "No Input"
        }
        return device.name
    }

    /// Subtle display of both default devices in header
    private var defaultDevicesStatus: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            // Output device
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9))
                Text(defaultOutputDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Separator
            Text("·")

            // Input device
            HStack(spacing: 3) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9))
                Text(defaultInputDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(DesignTokens.Colors.textSecondary)
    }

    // MARK: - Device Toggle

    /// Icon-only pill toggle for switching between Output and Input devices
    private var deviceTabsHeader: some View {
        let iconSize: CGFloat = 13
        let buttonSize: CGFloat = 26

        return HStack(spacing: 2) {
            // Output (speaker) button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    showingInputDevices = false
                }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(showingInputDevices ? DesignTokens.Colors.textTertiary : DesignTokens.Colors.textPrimary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        if !showingInputDevices {
                            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                .fill(.white.opacity(0.1))
                                .matchedGeometryEffect(id: "deviceToggle", in: deviceToggleNamespace)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Output Devices")

            // Input (mic) button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    showingInputDevices = true
                }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(showingInputDevices ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        if showingInputDevices {
                            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                .fill(.white.opacity(0.1))
                                .matchedGeometryEffect(id: "deviceToggle", in: deviceToggleNamespace)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Input Devices")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private var devicesSection: some View {
        let devices = showingInputDevices ? sortedInputDevices : sortedDevices
        let threshold = deviceScrollThreshold

        if !isEditingDevicePriority && devices.count > threshold {
            ScrollView {
                devicesContent
            }
            .scrollIndicators(.never)
            .frame(height: deviceScrollHeight)
        } else {
            devicesContent
        }
    }

    private var devicesContent: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            if isEditingDevicePriority {
                // Edit mode: drag-and-drop reordering (works for both output and input)
                let defaultDeviceID = showingInputDevices
                    ? deviceVolumeMonitor.defaultInputDeviceID
                    : deviceVolumeMonitor.defaultDeviceID
                ForEach(Array(editableDeviceOrder.enumerated()), id: \.element.uid) { index, device in
                    let isDeviceHidden = showingInputDevices
                        ? audioEngine.settingsManager.isInputDeviceHidden(device.uid)
                        : audioEngine.settingsManager.isOutputDeviceHidden(device.uid)
                    DeviceEditRow(
                        device: device,
                        priorityIndex: index,
                        isDefault: device.id == defaultDeviceID,
                        isInputDevice: showingInputDevices,
                        deviceCount: editableDeviceOrder.count,
                        onReorder: { newIndex in
                            guard let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }) else { return }
                            guard newIndex != fromIndex, newIndex >= 0, newIndex < editableDeviceOrder.count else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                editableDeviceOrder.move(
                                    fromOffsets: IndexSet(integer: fromIndex),
                                    toOffset: newIndex > fromIndex ? newIndex + 1 : newIndex
                                )
                            }
                        },
                        isHidden: isDeviceHidden,
                        onToggleHidden: {
                            if showingInputDevices {
                                if audioEngine.settingsManager.isInputDeviceHidden(device.uid) {
                                    audioEngine.settingsManager.unhideInputDevice(uid: device.uid)
                                } else {
                                    audioEngine.settingsManager.hideInputDevice(uid: device.uid)
                                }
                            } else {
                                if audioEngine.settingsManager.isOutputDeviceHidden(device.uid) {
                                    audioEngine.settingsManager.unhideOutputDevice(uid: device.uid)
                                } else {
                                    audioEngine.settingsManager.hideOutputDevice(uid: device.uid)
                                }
                            }
                        }
                    )
                    .draggable(device.uid) {
                        Text(device.name)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .dropDestination(for: String.self) { droppedUIDs, _ in
                        guard let droppedUID = droppedUIDs.first,
                              let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == droppedUID }),
                              let toIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }),
                              fromIndex != toIndex else { return false }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            editableDeviceOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                        }
                        return true
                    }
                }

                // Paired Bluetooth devices (output tab only)
                if !showingInputDevices {
                    if !isBluetoothOn {
                        Text("Turn on Bluetooth to connect devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, DesignTokens.Spacing.xs)
                    } else {
                        // Filter out any device already in the output list (handles
                        // IOBluetooth/CoreAudio timing desync where both report the device).
                        let connectedNames = Set(editableDeviceOrder.map(\.name))
                        let filteredPaired = pairedDevices.filter { !connectedNames.contains($0.name) }
                        if !filteredPaired.isEmpty {
                            SectionHeader(title: "Paired")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, DesignTokens.Spacing.xs)

                            ForEach(filteredPaired) { device in
                                PairedDeviceRow(
                                    device: device,
                                    isConnecting: audioEngine.bluetoothDeviceMonitor.connectingIDs.contains(device.id),
                                    errorMessage: audioEngine.bluetoothDeviceMonitor.connectionErrors[device.id],
                                    onConnect: {
                                        audioEngine.bluetoothDeviceMonitor.connect(device: device)
                                    }
                                )
                            }
                        }
                    }
                }
            } else if showingInputDevices {
                ForEach(sortedInputDevices) { device in
                    InputDeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultInputDeviceID,
                        volume: deviceVolumeMonitor.inputVolumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.inputMuteStates[device.id] ?? false,
                        onSetDefault: {
                            audioEngine.setLockedInputDevice(device)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setInputVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.inputMuteStates[device.id] ?? false
                            deviceVolumeMonitor.setInputMute(for: device.id, to: !currentMute)
                        }
                    )
                }
            } else {
                ForEach(sortedDevices) { device in
                    let selection = audioEngine.getAutoEQSelection(for: device.uid)
                    let profileName: String? = {
                        guard let sel = selection else { return nil }
                        return audioEngine.autoEQProfileManager.profile(for: sel.profileID)?.name
                            ?? audioEngine.autoEQProfileManager.catalogEntry(for: sel.profileID)?.name
                    }()

                    DeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                        volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                        hasVolumeControl: audioEngine.hasVolumeControl(for: device.id),
                        volumeBackend: audioEngine.outputVolumeBackend(for: device.id),
                        onSetDefault: {
                            audioEngine.setDefaultOutputDevice(device.id)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                            deviceVolumeMonitor.setMute(for: device.id, to: !currentMute)
                        },
                        autoEQProfileName: profileName,
                        autoEQEnabled: selection?.isEnabled ?? false,
                        onAutoEQToggle: { enabled in
                            audioEngine.setAutoEQEnabled(for: device.uid, enabled: enabled)
                        },
                        autoEQProfileManager: audioEngine.autoEQProfileManager,
                        autoEQSelection: selection,
                        autoEQFavoriteIDs: audioEngine.settingsManager.favoriteAutoEQProfileIDs,
                        onAutoEQSelect: { profile in
                            audioEngine.setAutoEQProfile(for: device.uid, profileID: profile?.id)
                        },
                        onAutoEQImport: {
                            importAutoEQFile(for: device.uid)
                        },
                        onAutoEQToggleFavorite: { id in
                            if audioEngine.settingsManager.isAutoEQFavorite(id: id) {
                                audioEngine.settingsManager.unfavoriteAutoEQProfile(id: id)
                            } else {
                                audioEngine.settingsManager.favoriteAutoEQProfile(id: id)
                            }
                        },
                        autoEQImportError: autoEQImportError,
                        autoEQPreampEnabled: audioEngine.autoEQPreampEnabled,
                        onAutoEQPreampToggle: {
                            audioEngine.setAutoEQPreampEnabled(!audioEngine.autoEQPreampEnabled)
                        }
                    )
                }

            }
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text("No apps playing audio")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                let ignoredCount = audioEngine.settingsManager.getIgnoredAppInfo().count
                if ignoredCount > 0 {
                    Text("\(ignoredCount) ignored · edit to manage")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private var appsSection: some View {
        HStack {
            SectionHeader(title: "Apps")
            Spacer()
            let ignoredCount = audioEngine.settingsManager.getIgnoredAppInfo().count
            if ignoredCount > 0 && !isEditingDevicePriority {
                Text("\(ignoredCount) ignored")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.bottom, DesignTokens.Spacing.xs)

        if permission.status != .authorized {
            PermissionBannerView(permission: permission)
        } else if isEditingDevicePriority {
            appEditModeContent
        } else if audioEngine.displayableApps.isEmpty {
            emptyStateView
        } else {
            ScrollViewReader { scrollProxy in
                if audioEngine.displayableApps.count > appScrollThreshold {
                    ScrollView {
                        appsContent(scrollProxy: scrollProxy)
                    }
                    .scrollIndicators(.never)
                    .frame(height: appScrollHeight)
                } else {
                    appsContent(scrollProxy: scrollProxy)
                }
            }
        }
    }

    /// Edit mode content for apps: simplified rows with eye toggle + hidden section at bottom.
    private let appEditColumns = [
        GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
        GridItem(.flexible(), spacing: DesignTokens.Spacing.xs)
    ]

    @ViewBuilder
    private var appEditModeContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // Visible apps in 2-column grid
            LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                ForEach(audioEngine.displayableApps) { displayableApp in
                    switch displayableApp {
                    case .active(let app):
                        AppEditRow(
                            icon: app.icon,
                            name: app.name,
                            isIgnored: false,
                            isPinned: audioEngine.isPinned(app),
                            onToggleVisibility: { audioEngine.ignoreApp(app) },
                            onTogglePin: {
                                if audioEngine.isPinned(app) {
                                    audioEngine.unpinApp(app.persistenceIdentifier)
                                } else {
                                    audioEngine.pinApp(app)
                                }
                            }
                        )
                    case .pinnedInactive(let info):
                        AppEditRow(
                            icon: displayableApp.icon,
                            name: info.displayName,
                            isIgnored: false,
                            isPinned: true,
                            onToggleVisibility: {
                                let hiddenInfo = IgnoredAppInfo(
                                    persistenceIdentifier: info.persistenceIdentifier,
                                    displayName: info.displayName,
                                    bundleID: info.bundleID
                                )
                                audioEngine.settingsManager.ignoreApp(info.persistenceIdentifier, info: hiddenInfo)
                            },
                            onTogglePin: {
                                audioEngine.unpinApp(info.persistenceIdentifier)
                            }
                        )
                    }
                }
            }

            // Ignored apps section
            let ignoredApps = audioEngine.settingsManager.getIgnoredAppInfo()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if !ignoredApps.isEmpty {
                Divider()
                    .padding(.vertical, DesignTokens.Spacing.xs)

                Text("Ignored")
                    .sectionHeaderStyle()
                    .padding(.bottom, DesignTokens.Spacing.xs)

                LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                    ForEach(ignoredApps, id: \.persistenceIdentifier) { info in
                        AppEditRow(
                            icon: DisplayableApp.loadIcon(bundleID: info.bundleID),
                            name: info.displayName,
                            isIgnored: true,
                            isPinned: false,
                            onToggleVisibility: { audioEngine.unignoreApp(info.persistenceIdentifier) },
                            onTogglePin: {}
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appsContent(scrollProxy: ScrollViewProxy) -> some View {
        let presets = audioEngine.settingsManager.getUserPresets()
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(audioEngine.displayableApps) { displayableApp in
                switch displayableApp {
                case .active(let app):
                    activeAppRow(app: app, displayableApp: displayableApp, userPresets: presets, scrollProxy: scrollProxy)

                case .pinnedInactive(let info):
                    inactiveAppRow(info: info, displayableApp: displayableApp, userPresets: presets, scrollProxy: scrollProxy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Row for an active app (currently producing audio)
    @ViewBuilder
    private func activeAppRow(app: AudioApp, displayableApp: DisplayableApp, userPresets: [UserEQPreset], scrollProxy: ScrollViewProxy) -> some View {
        if let deviceUID = audioEngine.getDeviceUID(for: app) {
            AppRowWithLevelPolling(
                app: app,
                volume: audioEngine.getVolume(for: app),
                isMuted: audioEngine.getMute(for: app),
                devices: sortedDevices,
                selectedDeviceUID: deviceUID,
                selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDs(for: app),
                isFollowingDefault: audioEngine.isFollowingDefault(for: app),
                defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                deviceSelectionMode: audioEngine.getDeviceSelectionMode(for: app),
                boost: audioEngine.getBoost(for: app),
                onBoostChange: { boost in
                    audioEngine.setBoost(for: app, to: boost)
                },
                getAudioLevel: { audioEngine.getAudioLevel(for: app) },
                isPopupVisible: isPopupVisible,
                onVolumeChange: { volume in
                    audioEngine.setVolume(for: app, to: volume)
                },
                onMuteChange: { muted in
                    audioEngine.setMute(for: app, to: muted)
                },
                onDeviceSelected: { newDeviceUID in
                    audioEngine.setDevice(for: app, deviceUID: newDeviceUID)
                },
                onDevicesSelected: { uids in
                    audioEngine.setSelectedDeviceUIDs(for: app, to: uids)
                },
                onDeviceModeChange: { mode in
                    audioEngine.setDeviceSelectionMode(for: app, to: mode)
                },
                onSelectFollowDefault: {
                    audioEngine.setDevice(for: app, deviceUID: nil)
                },
                onAppActivate: {
                    activateApp(pid: app.id, bundleID: app.bundleID)
                },
                eqSettings: audioEngine.getEQSettings(for: app),
                userPresets: userPresets,
                onEQChange: { settings in
                    audioEngine.setEQSettings(settings, for: app)
                },
                onUserPresetSelected: { userPreset in
                    // Apply only bandGains — preserve app's current isEnabled state
                    var current = audioEngine.getEQSettings(for: app)
                    current.bandGains = userPreset.settings.bandGains
                    audioEngine.setEQSettings(current, for: app)
                },
                onSavePreset: { name, settings in
                    audioEngine.settingsManager.createUserPreset(name: name, settings: settings)
                },
                onDeleteUserPreset: { id in
                    audioEngine.settingsManager.deleteUserPreset(id: id)
                },
                onRenameUserPreset: { id, newName in
                    audioEngine.settingsManager.updateUserPreset(id: id, name: newName)
                },
                isEQExpanded: expandedRowID == displayableApp.id,
                onEQToggle: {
                    toggleEQ(for: displayableApp.id, scrollProxy: scrollProxy)
                }
            )
            .id(displayableApp.id)
        }
    }

    /// Row for a pinned inactive app (not currently producing audio)
    @ViewBuilder
    private func inactiveAppRow(info: PinnedAppInfo, displayableApp: DisplayableApp, userPresets: [UserEQPreset], scrollProxy: ScrollViewProxy) -> some View {
        let identifier = info.persistenceIdentifier
        InactiveAppRow(
            appInfo: info,
            icon: displayableApp.icon,
            volume: audioEngine.getVolumeForInactive(identifier: identifier),
            devices: sortedDevices,
            selectedDeviceUID: audioEngine.getDeviceRoutingForInactive(identifier: identifier),
            selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDsForInactive(identifier: identifier),
            isFollowingDefault: audioEngine.isFollowingDefaultForInactive(identifier: identifier),
            defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
            deviceSelectionMode: audioEngine.getDeviceSelectionModeForInactive(identifier: identifier),
            isMuted: audioEngine.getMuteForInactive(identifier: identifier),
            boost: audioEngine.getBoostForInactive(identifier: identifier),
            onBoostChange: { boost in
                audioEngine.setBoostForInactive(identifier: identifier, to: boost)
            },
            onVolumeChange: { volume in
                audioEngine.setVolumeForInactive(identifier: identifier, to: volume)
            },
            onMuteChange: { muted in
                audioEngine.setMuteForInactive(identifier: identifier, to: muted)
            },
            onDeviceSelected: { newDeviceUID in
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: newDeviceUID)
            },
            onDevicesSelected: { uids in
                audioEngine.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
            },
            onDeviceModeChange: { mode in
                audioEngine.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
            },
            onSelectFollowDefault: {
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: nil)
            },
            eqSettings: audioEngine.getEQSettingsForInactive(identifier: identifier),
            userPresets: userPresets,
            onEQChange: { settings in
                audioEngine.setEQSettingsForInactive(settings, identifier: identifier)
            },
            onUserPresetSelected: { userPreset in
                // Apply only bandGains — preserve app's current isEnabled state
                var current = audioEngine.getEQSettingsForInactive(identifier: identifier)
                current.bandGains = userPreset.settings.bandGains
                audioEngine.setEQSettingsForInactive(current, identifier: identifier)
            },
            onSavePreset: { name, settings in
                audioEngine.settingsManager.createUserPreset(name: name, settings: settings)
            },
            onDeleteUserPreset: { id in
                audioEngine.settingsManager.deleteUserPreset(id: id)
            },
            onRenameUserPreset: { id, newName in
                audioEngine.settingsManager.updateUserPreset(id: id, name: newName)
            },
            isEQExpanded: expandedRowID == displayableApp.id,
            onEQToggle: {
                toggleEQ(for: displayableApp.id, scrollProxy: scrollProxy)
            }
        )
        .id(displayableApp.id)
    }

    /// Toggle EQ panel for an app (shared between active and inactive rows)
    private func toggleEQ(for appID: String, scrollProxy: ScrollViewProxy) {
        guard !isEQAnimating else { return }
        isEQAnimating = true

        let isExpanding = expandedRowID != appID
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if expandedRowID == appID {
                expandedRowID = nil
            } else {
                expandedRowID = appID
            }
            if isExpanding {
                scrollProxy.scrollTo(appID, anchor: .top)
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(0.4))
            isEQAnimating = false
        }
    }

    // MARK: - Device Priority Edit

    private func toggleDevicePriorityEdit() {
        if isEditingDevicePriority {
            // Exiting edit mode: persist to the correct priority list
            persistEditableOrder()
            isEditingDevicePriority = false
            if wasEditingInputDevices {
                updateSortedInputDevices()
            } else {
                updateSortedDevices()
            }
        } else {
            // Entering edit mode: use the full (unfiltered) device list so hidden devices are also shown.
            wasEditingInputDevices = showingInputDevices
            editableDeviceOrder = showingInputDevices
                ? audioEngine.prioritySortedInputDevices
                : audioEngine.prioritySortedOutputDevices
            isEditingDevicePriority = true
        }
    }

    /// Persists the editable order to the correct priority list, preserving disconnected device positions.
    private func persistEditableOrder() {
        let connectedOrder = editableDeviceOrder.map(\.uid)
        if wasEditingInputDevices {
            audioEngine.settingsManager.mergeInputDevicePriorityOrder(
                oldPriority: audioEngine.settingsManager.inputDevicePriorityOrder,
                connectedOrder: connectedOrder
            )
        } else {
            audioEngine.settingsManager.mergeDevicePriorityOrder(
                oldPriority: audioEngine.settingsManager.devicePriorityOrder,
                connectedOrder: connectedOrder
            )
        }
    }

    /// Exits edit mode, saving the current order. Called on edge cases like device changes.
    private func exitEditModeSaving() {
        guard isEditingDevicePriority else { return }
        persistEditableOrder()
        isEditingDevicePriority = false
    }

    /// Merges device list changes into `editableDeviceOrder` while preserving the user's reordering.
    /// Existing devices are refreshed (CoreAudio may reassign AudioDeviceIDs), removed devices are
    /// dropped, and reconnecting devices are inserted at their saved priority position.
    private func mergeDeviceChanges(from latest: [AudioDevice]) {
        let latestByUID = Dictionary(latest.map { ($0.uid, $0) }, uniquingKeysWith: { _, new in new })
        let priorityOrder = wasEditingInputDevices
            ? audioEngine.settingsManager.inputDevicePriorityOrder
            : audioEngine.settingsManager.devicePriorityOrder

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            // Remove devices that disappeared
            editableDeviceOrder.removeAll { latestByUID[$0.uid] == nil }

            // Refresh existing devices in case AudioDeviceID changed
            for i in editableDeviceOrder.indices {
                if let updated = latestByUID[editableDeviceOrder[i].uid] {
                    editableDeviceOrder[i] = updated
                }
            }

            // Insert reconnecting devices at their saved priority position
            let existingUIDs = Set(editableDeviceOrder.map(\.uid))
            let newDevices = latest.filter { !existingUIDs.contains($0.uid) }
            for device in newDevices {
                let index = Self.priorityInsertionIndex(
                    for: device.uid,
                    in: editableDeviceOrder.map(\.uid),
                    priorityOrder: priorityOrder
                )
                editableDeviceOrder.insert(device, at: index)
            }
        }
    }

    /// Finds the best insertion index for a reconnecting device based on saved priority order.
    ///
    /// Walks `priorityOrder` to find the UIDs that come before and after `uid`, then
    /// places the device between them in `currentOrder`. Falls back to appending at the end
    /// if the device isn't in the priority list or no neighbors are present.
    ///
    /// - Parameters:
    ///   - uid: The device UID to insert.
    ///   - currentOrder: The current list of device UIDs.
    ///   - priorityOrder: The saved full priority list.
    /// - Returns: The index at which to insert the device.
    static func priorityInsertionIndex(for uid: String, in currentOrder: [String], priorityOrder: [String]) -> Int {
        guard let priorityIndex = priorityOrder.firstIndex(of: uid) else {
            // Brand new device not in priority list — append at end
            return currentOrder.count
        }

        // Find the closest priority neighbor that exists in currentOrder and comes AFTER uid in priority.
        // Insert before that neighbor so uid takes its correct position.
        for i in (priorityIndex + 1)..<priorityOrder.count {
            let successor = priorityOrder[i]
            if let currentIndex = currentOrder.firstIndex(of: successor) {
                return currentIndex
            }
        }

        // No successor found — insert at end
        return currentOrder.count
    }

    // MARK: - Helpers

    /// Recomputes sorted output devices, filtering hidden ones.
    /// The current default output device is always kept visible even if hidden.
    private func updateSortedDevices() {
        let defaultUID = deviceVolumeMonitor.defaultDeviceUID
        sortedDevices = audioEngine.prioritySortedOutputDevices.filter { device in
            device.uid == defaultUID || !audioEngine.settingsManager.isOutputDeviceHidden(device.uid)
        }
    }

    /// Recomputes sorted input devices, filtering hidden ones.
    /// The current default input device is always kept visible even if hidden.
    private func updateSortedInputDevices() {
        let defaultUID = deviceVolumeMonitor.defaultInputDeviceUID
        sortedInputDevices = audioEngine.prioritySortedInputDevices.filter { device in
            device.uid == defaultUID || !audioEngine.settingsManager.isInputDeviceHidden(device.uid)
        }
    }

    /// Opens a file panel to import a ParametricEQ.txt for a device
    private func importAutoEQFile(for deviceUID: String) {
        // Dismiss the main popup so the file picker isn't obscured
        NSApp.keyWindow?.resignKey()

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an AutoEQ ParametricEQ.txt file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task { @MainActor in
                if let profile = audioEngine.autoEQProfileManager.importProfile(from: url, name: name) {
                    audioEngine.setAutoEQProfile(for: deviceUID, profileID: profile.id)
                    autoEQImportError = nil
                } else {
                    autoEQImportError = "Could not read profile — check file format"
                    importErrorClearTask?.cancel()
                    importErrorClearTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        withAnimation { autoEQImportError = nil }
                    }
                }
            }
        }
    }

    /// Activates an app, bringing it to foreground and restoring minimized windows
    private func activateApp(pid: pid_t, bundleID: String?) {
        // Step 1: Always activate via NSRunningApplication (reliable for non-minimized)
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        runningApp?.activate()

        // Step 2: Try to restore minimized windows via AppleScript
        if let bundleID = bundleID {
            // reopen + activate restores minimized windows for most apps
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)"
                    reopen
                    activate
                end tell
                """)
            script?.executeAndReturnError(nil)
        }
    }
}

// MARK: - Previews

#Preview("Menu Bar Popup") {
    // Note: This preview requires mock AudioEngine and DeviceVolumeMonitor
    // For now, just show the structure
    PreviewContainer {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Output Devices")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleDevices.prefix(2)) { device in
                DeviceRow(
                    device: device,
                    isDefault: device == MockData.sampleDevices[0],
                    volume: 0.75,
                    isMuted: false,
                    onSetDefault: {},
                    onVolumeChange: { _ in },
                    onMuteToggle: {}
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            SectionHeader(title: "Apps")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleApps.prefix(3)) { app in
                AppRow(
                    app: app,
                    volume: Float.random(in: 0.5...1.5),
                    audioLevel: Float.random(in: 0...0.7),
                    devices: MockData.sampleDevices,
                    selectedDeviceUID: MockData.sampleDevices[0].uid,
                    isMuted: false,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in }
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            Button("Quit FineTune") {}
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .font(DesignTokens.Typography.caption)
        }
    }
}
