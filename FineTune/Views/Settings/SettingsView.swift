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

            SettingsSliderRow(
                icon: "speaker.wave.3",
                title: "Max Volume Boost",
                description: "Safety limit for volume slider",
                value: $settings.maxVolumeBoost,
                range: 1.0...4.0
            )

            SettingsToggleRow(
                icon: "slider.vertical.3",
                title: "Enable EQ by Default",
                description: "Automatically enable equalizer for new apps",
                isOn: $settings.defaultEQEnabled
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
        let currentYear = Calendar.current.component(.year, from: Date())
        let yearText = startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"

        return HStack(spacing: DesignTokens.Spacing.xs) {
            Link(destination: URL(string: "https://github.com/ronitsingh10/FineTune")!) {
                Text("\(Image(systemName: "star")) Star on GitHub")
            }

            Text("·")

            Text("Copyright © \(yearText) Ronit Singh")
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
