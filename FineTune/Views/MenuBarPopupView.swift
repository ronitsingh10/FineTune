// FineTune/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @ObservedObject var updateManager: UpdateManager

    /// Icon style that was applied at app launch (for restart-required detection)
    let launchIconStyle: MenuBarIconStyle

    /// Memoized sorted output devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Memoized sorted input devices
    @State private var sortedInputDevices: [AudioDevice] = []

    /// Which device tab is selected (false = output, true = input)
    @State private var showingInputDevices = false

    /// Track which app has its EQ panel expanded (only one at a time)
    /// Uses DisplayableApp.id (String) to work with both active and inactive apps
    @State private var expandedEQAppID: String?

    /// Debounce EQ toggle to prevent rapid clicks during animation
    @State private var isEQAnimating = false

    /// Track popup visibility to pause VU meter polling when hidden
    @State private var isPopupVisible = true

    /// Track whether settings panel is open
    @State private var isSettingsOpen = false

    /// Debounce settings toggle to prevent rapid clicks during animation
    @State private var isSettingsAnimating = false

    /// Local copy of app settings for binding
    @State private var localAppSettings: AppSettings = AppSettings()

    /// Whether device priority edit mode is active
    @State private var isEditingDevicePriority = false

    /// Tracks which tab was active when edit mode started (for correct save on exit)
    @State private var wasEditingInputDevices = false

    /// Editable copy of device order for drag-and-drop reordering
    @State private var editableDeviceOrder: [AudioDevice] = []

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
                        audioEngine.settingsManager.resetAllSettings()
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
            localAppSettings = audioEngine.settingsManager.appSettings
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            exitEditModeSaving()
            updateSortedDevices()
        }
        .onChange(of: audioEngine.inputDevices) { _, _ in
            exitEditModeSaving()
            updateSortedInputDevices()
        }
        .onChange(of: showingInputDevices) { _, _ in
            exitEditModeSaving()
        }
        .onChange(of: localAppSettings) { _, newValue in
            audioEngine.settingsManager.updateAppSettings(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isPopupVisible = true
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
        Button {
            toggleDevicePriorityEdit()
        } label: {
            Image(systemName: isEditingDevicePriority ? "checkmark" : "pencil")
                .font(.system(size: 12, weight: isEditingDevicePriority ? .bold : .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEditingDevicePriority)
        .help(isEditingDevicePriority ? "Done reordering" : "Reorder devices")
    }

    // MARK: - Settings Button

    /// Settings button with gear ↔ X morphing animation
    private var settingsButton: some View {
        Button {
            toggleSettings()
        } label: {
            Image(systemName: isSettingsOpen ? "xmark" : "gearshape.fill")
                .font(.system(size: 12, weight: isSettingsOpen ? .bold : .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .rotationEffect(.degrees(isSettingsOpen ? 90 : 0))
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSettingsOpen)
    }

    /// Handles Escape key: closes settings/EQ first, then dismisses the popup
    private func handleEscape() {
        if isSettingsOpen {
            toggleSettings()
        } else if expandedEQAppID != nil {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expandedEQAppID = nil
            }
        } else {
            NSApp.keyWindow?.orderOut(nil)
        }
    }

    private func toggleSettings() {
        guard !isSettingsAnimating else { return }
        exitEditModeSaving()
        isSettingsAnimating = true

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isSettingsOpen.toggle()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
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

        // Apps section (active + pinned inactive)
        if audioEngine.displayableApps.isEmpty {
            emptyStateView
        } else {
            appsSection
        }

        Divider()
            .padding(.vertical, DesignTokens.Spacing.xs)

        // Quit button
        HStack {
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
                    DeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                        volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                        hasVolumeControl: audioEngine.hasVolumeControl(for: device.id),
                        onSetDefault: {
                            deviceVolumeMonitor.setDefaultDevice(device.id)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                            deviceVolumeMonitor.setMute(for: device.id, to: !currentMute)
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
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private var appsSection: some View {
        SectionHeader(title: "Apps")
            .padding(.bottom, DesignTokens.Spacing.xs)

        // ScrollViewReader needed for EQ expand scroll-to behavior
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

    private func appsContent(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(audioEngine.displayableApps) { displayableApp in
                switch displayableApp {
                case .active(let app):
                    activeAppRow(app: app, displayableApp: displayableApp, scrollProxy: scrollProxy)

                case .pinnedInactive(let info):
                    inactiveAppRow(info: info, displayableApp: displayableApp, scrollProxy: scrollProxy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Row for an active app (currently producing audio)
    @ViewBuilder
    private func activeAppRow(app: AudioApp, displayableApp: DisplayableApp, scrollProxy: ScrollViewProxy) -> some View {
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
                maxVolumeBoost: audioEngine.settingsManager.appSettings.maxVolumeBoost,
                isPinned: audioEngine.isPinned(app),
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
                onPinToggle: {
                    if audioEngine.isPinned(app) {
                        audioEngine.unpinApp(app.persistenceIdentifier)
                    } else {
                        audioEngine.pinApp(app)
                    }
                },
                eqSettings: audioEngine.getEQSettings(for: app),
                onEQChange: { settings in
                    audioEngine.setEQSettings(settings, for: app)
                },
                isEQExpanded: expandedEQAppID == displayableApp.id,
                onEQToggle: {
                    toggleEQ(for: displayableApp.id, scrollProxy: scrollProxy)
                }
            )
            .id(displayableApp.id)
        }
    }

    /// Row for a pinned inactive app (not currently producing audio)
    @ViewBuilder
    private func inactiveAppRow(info: PinnedAppInfo, displayableApp: DisplayableApp, scrollProxy: ScrollViewProxy) -> some View {
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
            maxVolumeBoost: audioEngine.settingsManager.appSettings.maxVolumeBoost,
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
            onUnpin: {
                audioEngine.unpinApp(identifier)
            },
            eqSettings: audioEngine.getEQSettingsForInactive(identifier: identifier),
            onEQChange: { settings in
                audioEngine.setEQSettingsForInactive(settings, identifier: identifier)
            },
            isEQExpanded: expandedEQAppID == displayableApp.id,
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

        let isExpanding = expandedEQAppID != appID
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if expandedEQAppID == appID {
                expandedEQAppID = nil
            } else {
                expandedEQAppID = appID
            }
            if isExpanding {
                scrollProxy.scrollTo(appID, anchor: .top)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
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
            // Entering edit mode: copy the current tab's sorted devices
            wasEditingInputDevices = showingInputDevices
            editableDeviceOrder = showingInputDevices ? sortedInputDevices : sortedDevices
            isEditingDevicePriority = true
        }
    }

    /// Persists the editable order to the correct priority list.
    private func persistEditableOrder() {
        let uids = editableDeviceOrder.map(\.uid)
        if wasEditingInputDevices {
            audioEngine.settingsManager.setInputDevicePriorityOrder(uids)
        } else {
            audioEngine.settingsManager.setDevicePriorityOrder(uids)
        }
    }

    /// Exits edit mode, saving the current order. Called on edge cases like device changes.
    private func exitEditModeSaving() {
        guard isEditingDevicePriority else { return }
        persistEditableOrder()
        isEditingDevicePriority = false
    }

    // MARK: - Helpers

    /// Recomputes sorted output devices using priority order
    private func updateSortedDevices() {
        sortedDevices = audioEngine.prioritySortedOutputDevices
    }

    /// Recomputes sorted input devices using priority order
    private func updateSortedInputDevices() {
        sortedInputDevices = audioEngine.prioritySortedInputDevices
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
