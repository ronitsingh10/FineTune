// FineTune/Views/MenuBarPopupView.swift
import SwiftUI
import UniformTypeIdentifiers

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

    /// Track which output device has its EQ panel expanded (only one at a time)
    @State private var expandedDeviceEQUID: String?

    /// Debounce device EQ toggle to prevent rapid clicks during animation
    @State private var isDeviceEQAnimating = false

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

    /// Defers state reset until next popup open so dismiss is visually silent.
    @State private var shouldResetOnNextOpen = false

    /// Local copy of app settings for binding
    @State private var localAppSettings: AppSettings = AppSettings()

    /// Memoized paired Bluetooth devices
    @State private var pairedDevices: [PairedBluetoothDevice] = []

    /// Whether Bluetooth hardware is powered on
    @State private var isBluetoothOn = false

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
            applyPendingDismissResetIfNeeded()
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
        .onChange(of: localAppSettings) { _, newValue in
            audioEngine.settingsManager.updateAppSettings(newValue)
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
            applyPendingDismissResetIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isPopupVisible = false
            exitEditModeSaving()
            shouldResetOnNextOpen = true
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

    /// Handles Escape key: closes settings/device EQ first, then dismisses the popup
    private func handleEscape() {
        if isSettingsOpen {
            toggleSettings()
        } else if expandedDeviceEQUID != nil {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expandedDeviceEQUID = nil
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isSettingsAnimating = false
        }
    }

    /// Resets UI state that should not persist across popup closes.
    /// Keeps next open on the main page instead of Settings.
    private func resetTransientViewStateForDismiss() {
        isSettingsOpen = false
        isSettingsAnimating = false
        expandedDeviceEQUID = nil
        isDeviceEQAnimating = false
    }

    private func applyPendingDismissResetIfNeeded() {
        guard shouldResetOnNextOpen else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            resetTransientViewStateForDismiss()
        }
        shouldResetOnNextOpen = false
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
                        isHidden: audioEngine.isDeviceHidden(uid: device.uid, isInput: showingInputDevices),
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
                        onToggleHidden: {
                            let currentlyHidden = audioEngine.isDeviceHidden(uid: device.uid, isInput: showingInputDevices)
                            audioEngine.setDeviceHidden(uid: device.uid, isInput: showingInputDevices, hidden: !currentlyHidden)
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
                        currentSampleRate: audioEngine.currentSampleRate(for: device.id),
                        availableSampleRates: audioEngine.availableSampleRates(for: device.id),
                        canSetSampleRate: audioEngine.canSetSampleRate(for: device.id),
                        canDisconnectBluetooth: audioEngine.canDisconnectBluetooth(for: device),
                        onSetDefault: {
                            audioEngine.setLockedInputDevice(device)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setInputVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.inputMuteStates[device.id] ?? false
                            deviceVolumeMonitor.setInputMute(for: device.id, to: !currentMute)
                        },
                        onSampleRateChange: { rate in
                            audioEngine.setSampleRate(for: device, to: rate)
                        },
                        onDisconnectBluetooth: {
                            audioEngine.disconnectBluetooth(device: device)
                        }
                    )
                }
            } else {
                ForEach(sortedDevices) { device in
                    let eqSupported = audioEngine.isDeviceEQSupported(for: device.id)
                    DeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                        volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                        hasVolumeControl: audioEngine.hasVolumeControl(for: device.id),
                        currentSampleRate: audioEngine.currentSampleRate(for: device.id),
                        availableSampleRates: audioEngine.availableSampleRates(for: device.id),
                        canSetSampleRate: audioEngine.canSetSampleRate(for: device.id),
                        canDisconnectBluetooth: audioEngine.canDisconnectBluetooth(for: device),
                        eqSettings: audioEngine.getDeviceEQSettings(for: device.uid),
                        isEQExpanded: eqSupported && expandedDeviceEQUID == device.uid,
                        canUseEQ: eqSupported,
                        eqDisabledReason: audioEngine.eqUnavailableReason(for: device.id),
                        onSetDefault: {
                            deviceVolumeMonitor.setDefaultDevice(device.id)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                            deviceVolumeMonitor.setMute(for: device.id, to: !currentMute)
                        },
                        onSampleRateChange: { rate in
                            audioEngine.setSampleRate(for: device, to: rate)
                        },
                        onDisconnectBluetooth: {
                            audioEngine.disconnectBluetooth(device: device)
                        },
                        onEQToggle: {
                            toggleDeviceEQ(for: device.uid)
                        },
                        onEQChange: { settings in
                            audioEngine.setDeviceEQSettings(for: device.uid, to: settings)
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

        if audioEngine.displayableApps.count > appScrollThreshold {
            ScrollView {
                appsContent
            }
            .scrollIndicators(.never)
            .frame(height: appScrollHeight)
        } else {
            appsContent
        }
    }

    private var appsContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(audioEngine.displayableApps) { displayableApp in
                switch displayableApp {
                case .active(let app):
                    activeAppRow(app: app)

                case .pinnedInactive(let info):
                    inactiveAppRow(info: info, displayableApp: displayableApp)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Row for an active app (currently producing audio)
    @ViewBuilder
    private func activeAppRow(app: AudioApp) -> some View {
        let isExcluded = audioEngine.isExcluded(app)
        let deviceUID = audioEngine.getDeviceUID(for: app)
            ?? deviceVolumeMonitor.defaultDeviceUID
            ?? sortedDevices.first?.uid
            ?? ""

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
            onExclude: {
                audioEngine.excludeApp(identifier: app.persistenceIdentifier)
            },
            onInclude: {
                audioEngine.includeApp(identifier: app.persistenceIdentifier)
            },
            isExcluded: isExcluded
        )
    }

    /// Row for a pinned inactive app (not currently producing audio)
    @ViewBuilder
    private func inactiveAppRow(info: PinnedAppInfo, displayableApp: DisplayableApp) -> some View {
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
            }
        )
        .id(displayableApp.id)
    }

    /// Toggle EQ panel for an output device.
    private func toggleDeviceEQ(for deviceUID: String) {
        guard !isDeviceEQAnimating else { return }
        isDeviceEQAnimating = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if expandedDeviceEQUID == deviceUID {
                expandedDeviceEQUID = nil
            } else {
                expandedDeviceEQUID = deviceUID
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isDeviceEQAnimating = false
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
            editableDeviceOrder = showingInputDevices ? audioEngine.prioritySortedInputDevices : audioEngine.prioritySortedOutputDevices
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

    /// Merges device list changes into `editableDeviceOrder` while preserving the user's reordering.
    /// Existing devices are refreshed (CoreAudio may reassign AudioDeviceIDs), removed devices are
    /// dropped, and new devices are appended at the end.
    private func mergeDeviceChanges(from latest: [AudioDevice]) {
        let latestByUID = Dictionary(latest.map { ($0.uid, $0) }, uniquingKeysWith: { _, new in new })

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            // Remove devices that disappeared
            editableDeviceOrder.removeAll { latestByUID[$0.uid] == nil }

            // Refresh existing devices in case AudioDeviceID changed
            for i in editableDeviceOrder.indices {
                if let updated = latestByUID[editableDeviceOrder[i].uid] {
                    editableDeviceOrder[i] = updated
                }
            }

            // Append newly appeared devices
            let existingUIDs = Set(editableDeviceOrder.map(\.uid))
            let newDevices = latest.filter { !existingUIDs.contains($0.uid) }
            editableDeviceOrder.append(contentsOf: newDevices)
        }
    }

    // MARK: - Helpers

    /// Recomputes sorted output devices using priority order
    private func updateSortedDevices() {
        sortedDevices = audioEngine.visiblePrioritySortedOutputDevices
    }

    /// Recomputes sorted input devices using priority order
    private func updateSortedInputDevices() {
        sortedInputDevices = audioEngine.visiblePrioritySortedInputDevices
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
                    currentSampleRate: 48000,
                    onSetDefault: {},
                    onVolumeChange: { _ in },
                    onMuteToggle: {},
                    onSampleRateChange: { _ in }
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
                    onDeviceSelected: { _ in },
                    onExclude: {}
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
