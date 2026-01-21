// FineTune/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Track which app has its EQ panel expanded (only one at a time)
    @State private var expandedEQAppID: pid_t?

    /// Debounce EQ toggle to prevent rapid clicks during animation
    @State private var isEQAnimating = false

    /// Track popup visibility to pause VU meter polling when hidden
    @State private var isPopupVisible = true

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
        .padding(DesignTokens.Spacing.lg)
        .frame(width: DesignTokens.Dimensions.popupWidth)
        .darkGlassBackground()
        .environment(\.colorScheme, .dark)
        .onAppear {
            updateSortedDevices()
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            updateSortedDevices()
        }
        .onChange(of: deviceVolumeMonitor.defaultDeviceID) { _, _ in
            updateSortedDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isPopupVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isPopupVisible = false
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var devicesSection: some View {
        SectionHeader(title: "Output Devices")
            .padding(.bottom, DesignTokens.Spacing.xs)

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
                        audioEngine.setDeviceForAllApps(device.uid)
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
                    .id(app.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    /// Recomputes sorted devices - called only when dependencies change
    private func updateSortedDevices() {
        let devices = audioEngine.outputDevices
        let defaultID = deviceVolumeMonitor.defaultDeviceID
        sortedDevices = devices.sorted { lhs, rhs in
            if lhs.id == defaultID { return true }
            if rhs.id == defaultID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
