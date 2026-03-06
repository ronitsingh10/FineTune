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
    @Bindable var settingsManager: SettingsManager
    let outputDevices: [AudioDevice]
    let onIncludeExcludedApp: (String) -> Void

    @State private var showResetConfirmation = false

    var body: some View {
        // Scrollable settings content
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                generalSection
                audioSection
                excludedAppsSection
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
                titleOffsetX: -4,
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

            maxVolumeBoostRow

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

    private var maxVolumeBoostRow: some View {
        let presets: [Float] = [1, 2, 3, 4]

        return SettingsRowView(
            icon: "speaker.wave.3",
            title: "Max Volume Boost",
            description: "Safety limit for volume slider"
        ) {
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    let isSelected = abs(settings.maxVolumeBoost - preset) < 0.001
                    Button {
                        settings.maxVolumeBoost = preset
                    } label: {
                        Text("\(Int(preset))x")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(isSelected ? DesignTokens.Colors.interactiveDefault.opacity(0.2) : .white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Excluded Apps Section

    private var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Excluded Apps")
                .padding(.bottom, DesignTokens.Spacing.xs)

            if settingsManager.excludedApps().isEmpty {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "nosign")
                        .font(.system(size: DesignTokens.Dimensions.iconSizeSmall))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)

                    Text("No excluded apps")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
                .hoverableRow()
            } else {
                ForEach(settingsManager.excludedApps(), id: \.self) { identifier in
                    SettingsRowView(
                        icon: "nosign",
                        title: identifier,
                        description: nil
                    ) {
                        Button("Include") {
                            onIncludeExcludedApp(identifier)
                        }
                        .buttonStyle(.plain)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                        .glassButtonStyle()
                    }
                }
            }
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
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
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

                    SettingsButtonRow(
                        icon: "power",
                        title: "Quit FineTune",
                        description: "Close FineTune immediately",
                        buttonLabel: "Quit"
                    ) {
                        NSApplication.shared.terminate(nil)
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
