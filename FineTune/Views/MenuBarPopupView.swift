// FineTune/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @ObservedObject var updateManager: UpdateManager

    /// Icon style that was applied at app launch (for restart-required detection)
    let launchIconStyle: MenuBarIconStyle

    /// Memoized sorted devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Track which app has its EQ panel expanded (only one at a time)
    @State private var expandedEQAppID: pid_t?

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
            // Header row - always visible, title changes based on state
            HStack {
                Text(isSettingsOpen ? "Settings" : "Output Devices")
                    .sectionHeaderStyle()
                Spacer()
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
                    },
                    deviceVolumeMonitor: deviceVolumeMonitor,
                    outputDevices: audioEngine.outputDevices
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
            localAppSettings = audioEngine.settingsManager.appSettings
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            updateSortedDevices()
        }
        .onChange(of: localAppSettings) { _, newValue in
            audioEngine.settingsManager.updateAppSettings(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isPopupVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isPopupVisible = false
        }
        .background {
            // Hidden button to handle ⌘, keyboard shortcut for toggling settings
            Button("") { toggleSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
        }
    }

    // MARK: - Settings Button

    /// Settings button with gear ↔ X morphing animation
    private var settingsButton: some View {
        Button {
            toggleSettings()
        } label: {
            ZStack {
                Image(systemName: "gearshape.fill")
                    .opacity(isSettingsOpen ? 0 : 1)
                    .rotationEffect(.degrees(isSettingsOpen ? 90 : 0))

                Image(systemName: "xmark")
                    .opacity(isSettingsOpen ? 1 : 0)
                    .rotationEffect(.degrees(isSettingsOpen ? 0 : -90))
            }
            .font(.system(size: 12))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(DesignTokens.Colors.interactiveDefault)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSettingsOpen)
    }

    private func toggleSettings() {
        guard !isSettingsAnimating else { return }
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
        // Output Devices section
        devicesSection

        Divider()
            .padding(.vertical, DesignTokens.Spacing.xs)

        // Apps section
        if audioEngine.apps.isEmpty {
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

    // MARK: - Subviews

    @ViewBuilder
    private var devicesSection: some View {
        if sortedDevices.count > deviceScrollThreshold {
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
            ForEach(sortedDevices) { device in
                DeviceRow(
                    device: device,
                    isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                    volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                    isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
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
            if audioEngine.apps.count > appScrollThreshold {
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
            ForEach(audioEngine.apps) { app in
                if let deviceUID = audioEngine.getDeviceUID(for: app) {
                    AppRowWithLevelPolling(
                        app: app,
                        volume: audioEngine.getVolume(for: app),
                        isMuted: audioEngine.getMute(for: app),
                        devices: audioEngine.outputDevices,
                        selectedDeviceUID: deviceUID,
                        isFollowingDefault: audioEngine.isFollowingDefault(for: app),
                        defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                        maxVolumeBoost: audioEngine.settingsManager.appSettings.maxVolumeBoost,
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
                        onSelectFollowDefault: {
                            audioEngine.setDevice(for: app, deviceUID: nil)
                        },
                        onAppActivate: {
                            activateApp(pid: app.id, bundleID: app.bundleID)
                        },
                        eqSettings: audioEngine.getEQSettings(for: app),
                        onEQChange: { settings in
                            audioEngine.setEQSettings(settings, for: app)
                        },
                        isEQExpanded: expandedEQAppID == app.id,
                        onEQToggle: {
                            // Debounce: ignore clicks during animation
                            guard !isEQAnimating else { return }
                            isEQAnimating = true

                            let isExpanding = expandedEQAppID != app.id
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                if expandedEQAppID == app.id {
                                    expandedEQAppID = nil
                                } else {
                                    expandedEQAppID = app.id
                                }
                                // Scroll in same animation transaction
                                if isExpanding {
                                    scrollProxy.scrollTo(app.id, anchor: .top)
                                }
                            }

                            // Re-enable after animation completes
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                isEQAnimating = false
                            }
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    /// Recomputes sorted devices - alphabetical order only (no "default first" reordering)
    private func updateSortedDevices() {
        let devices = audioEngine.outputDevices
        sortedDevices = devices.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
