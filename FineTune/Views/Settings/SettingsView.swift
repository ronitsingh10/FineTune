// FineTune/Views/Settings/SettingsView.swift
import SwiftUI

/// Main settings panel with all app-wide configuration options
struct SettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var updateManager: UpdateManager
    let launchIconStyle: MenuBarIconStyle
    let onResetAll: () -> Void

    // System sounds control
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    let outputDevices: [AudioDevice]

    @State private var showResetConfirmation = false
    @State private var isSupportHovered = false
    @State private var isStarHovered = false
    @State private var isLicenseHovered = false

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.loudnessCompensationEnabled && settings.loudnessEqualizationEnabled },
            set: { isEnabled in
                settings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        // Scrollable settings content
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                generalSection
                audioSection
                notificationsSection
                dataSection

                aboutFooter
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "General")
                .padding(.bottom, DesignTokens.Spacing.xs)

            SettingsToggleRow(
                icon: "power",
                title: "Launch at Login",
                description: "Start FineTune when you log in",
                isOn: $settings.launchAtLogin
            )

            SettingsIconPickerRow(
                icon: "menubar.rectangle",
                title: "Menu Bar Icon",
                selection: $settings.menuBarIconStyle,
                appliedStyle: launchIconStyle
            )

            SettingsUpdateRow(
                automaticallyChecks: Binding(
                    get: { updateManager.automaticallyChecksForUpdates },
                    set: { updateManager.automaticallyChecksForUpdates = $0 }
                ),
                lastCheckDate: updateManager.lastUpdateCheckDate,
                onCheckNow: { updateManager.checkForUpdates() }
            )
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Audio")
                .padding(.bottom, DesignTokens.Spacing.xs)

            SettingsSliderRow(
                icon: "speaker.wave.2",
                title: "Default Volume",
                description: "Initial volume for new apps",
                value: $settings.defaultNewAppVolume,
                range: 0.1...1.0
            )

            SettingsToggleRow(
                icon: "speaker.badge.exclamationmark",
                title: "Software Volume for Unsupported Devices",
                description: "Add volume sliders for outputs without native controls (e.g. HDMI TVs)",
                isOn: $settings.softwareDeviceVolumeEnabled
            )

            SettingsToggleRow(
                icon: "square.stack.3d.up",
                title: "Show Virtual Output Devices",
                description: "Include virtual outputs like BlackHole and Loopback in the device list",
                isOn: $settings.showVirtualOutputDevices
            )

            SettingsToggleRow(
                icon: "mic",
                title: "Lock Input Device",
                description: "Prevent auto-switching when devices connect",
                isOn: $settings.lockInputDevice
            )

            // Sound Effects device selection
            SoundEffectsDeviceRow(
                devices: outputDevices,
                selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                onDeviceSelected: { deviceUID in
                    if let device = outputDevices.first(where: { $0.uid == deviceUID }) {
                        deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                    }
                },
                onSelectFollowDefault: {
                    deviceVolumeMonitor.setSystemFollowDefault()
                }
            )

            // Sound Effects alert volume slider
            SettingsSliderRow(
                icon: "bell.and.waves.left.and.right",
                title: "Alert Volume",
                description: "Volume for alerts and notifications",
                value: Binding(
                    get: { deviceVolumeMonitor.alertVolume },
                    set: { deviceVolumeMonitor.setAlertVolume($0) }
                )
            )
            .task {
                // Poll alert volume for live sync with System Settings.
                // No CoreAudio property listener exists for alert volume —
                // AppleScript is the only read path, so periodic refresh is required.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }

            SettingsLoudnessCompensationRow(
                isOn: unifiedLoudnessToggleBinding
            )
        }
    }


    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Notifications")
                .padding(.bottom, DesignTokens.Spacing.xs)

            SettingsToggleRow(
                icon: "bell",
                title: "Device Disconnect Alerts",
                description: "Show notification when device disconnects",
                isOn: $settings.showDeviceDisconnectAlerts
            )
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Data")
                .padding(.bottom, DesignTokens.Spacing.xs)

            if showResetConfirmation {
                // Inline confirmation row
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                        .frame(width: DesignTokens.Dimensions.settingsIconWidth)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset all settings?")
                            .font(DesignTokens.Typography.rowName)
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                        Text("This cannot be undone")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }

                    Spacer()

                    Button("Cancel") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showResetConfirmation = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                    Button("Reset") {
                        onResetAll()
                        showResetConfirmation = false
                    }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                }
                .hoverableRow()
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                SettingsButtonRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset All Settings",
                    description: "Clear all volumes, EQ, and device routings",
                    buttonLabel: "Reset",
                    isDestructive: true
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showResetConfirmation = true
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    // MARK: - About Footer

    private var aboutFooter: some View {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
        let yearText = startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"

        return HStack(spacing: DesignTokens.Spacing.xs) {
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/ronitsingh10/FineTune")!)
            } label: {
                Text("\(Image(systemName: isStarHovered ? "star.fill" : "star")) Star on GitHub")
                    .foregroundStyle(isStarHovered ? Color(nsColor: .systemYellow) : DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isStarHovered = hovering
                }
            }
            .accessibilityLabel("Star FineTune on GitHub")

            Text("·")

            Button {
                NSWorkspace.shared.open(DesignTokens.Links.support)
            } label: {
                Text("\(Image(systemName: isSupportHovered ? "heart.fill" : "heart")) Support FineTune")
                    .foregroundStyle(isSupportHovered ? Color(nsColor: .systemPink) : DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isSupportHovered = hovering
                }
            }
            .accessibilityLabel("Support FineTune")

            Text("·")

            Text("Copyright © \(yearText) Ronit Singh")

            Text("·")

            Button {
                NSWorkspace.shared.open(DesignTokens.Links.license)
            } label: {
                Text("GPL-3.0")
                    .foregroundStyle(isLicenseHovered ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isLicenseHovered = hovering
                }
            }
            .accessibilityLabel("View GPL-3.0 license")
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(DesignTokens.Colors.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Spacing.sm)
    }
}

// MARK: - Previews

// Note: Preview requires mock DeviceVolumeMonitor which isn't available
// Use live testing instead
