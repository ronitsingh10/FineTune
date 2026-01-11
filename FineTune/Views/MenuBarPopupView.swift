// FineTune/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Track which app has its EQ panel expanded (only one at a time)
    @State private var expandedEQAppID: pid_t?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Output Devices section
            SectionHeader(title: "Output Devices")
                .padding(.bottom, DesignTokens.Spacing.xs)

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
            Button("Quit FineTune") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .font(DesignTokens.Typography.caption)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: DesignTokens.Dimensions.popupWidth)
        .darkGlassBackground()
        .onAppear {
            updateSortedDevices()
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            updateSortedDevices()
        }
        .onChange(of: deviceVolumeMonitor.defaultDeviceID) { _, _ in
            updateSortedDevices()
        }
    }

    // MARK: - Subviews

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

        ScrollView {
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
                            onVolumeChange: { volume in
                                audioEngine.setVolume(for: app, to: volume)
                            },
                            onMuteChange: { muted in
                                audioEngine.setMute(for: app, to: muted)
                            },
                            onDeviceSelected: { newDeviceUID in
                                audioEngine.setDevice(for: app, deviceUID: newDeviceUID)
                            },
                            eqSettings: audioEngine.getEQSettings(for: app),
                            onEQChange: { settings in
                                audioEngine.setEQSettings(settings, for: app)
                            },
                            isEQExpanded: expandedEQAppID == app.id,
                            onEQToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedEQAppID == app.id {
                                        expandedEQAppID = nil
                                    } else {
                                        expandedEQAppID = app.id
                                    }
                                }
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minHeight: min(CGFloat(audioEngine.apps.count) * 44, 180), maxHeight: DesignTokens.Dimensions.maxScrollHeight)
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
