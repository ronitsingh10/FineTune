// FineTune/Views/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var updateManager: UpdateManager
    let launchIconStyle: MenuBarIconStyle
    let onResetAll: () -> Void

    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    let outputDevices: [AudioDevice]
    let accessibilityPermission: AccessibilityPermission
    let softwareVolumeOutputs: [SoftwareVolumeOutputOption]
    let onSoftwareVolumeToggle: (String, Bool) -> Void

    @State private var showResetConfirmation = false
    @State private var showSoftwareVolumeOutputs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                generalSection
                audioSection
                softwareVolumeSection
                notificationsSection
                dataSection

                aboutFooter
            }
        }
        .scrollIndicators(.never)
    }

    private var softwareVolumeSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Software Volume Outputs")
                .padding(.bottom, DesignTokens.Spacing.xs)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSoftwareVolumeOutputs.toggle()
                    }
                } label: {
                    HStack(spacing: DesignTokens.Spacing.md) {
                        Image(systemName: "dial.medium")
                            .font(.system(size: DesignTokens.Dimensions.iconSizeSmall))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                            .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose Outputs")
                                .font(DesignTokens.Typography.rowName)
                                .foregroundStyle(DesignTokens.Colors.textPrimary)
                            Text("Use software volume for outputs that do not support hardware volume control. FineTune remembers disconnected devices.")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: DesignTokens.Spacing.sm)

                        Text("\(softwareVolumeOutputs.filter { $0.isEnabled }.count)")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)

                        Image(systemName: showSoftwareVolumeOutputs ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverableRow()

                if showSoftwareVolumeOutputs {
                    if softwareVolumeOutputs.isEmpty {
                        SettingsRowView(
                            icon: "speaker.slash",
                            title: "No outputs found",
                            description: "Connect an output device once and it will appear here."
                        ) {
                            EmptyView()
                        }
                    } else {
                        ForEach(softwareVolumeOutputs) { output in
                            SettingsRowView(
                                icon: output.isAvailable ? "speaker.wave.2" : "speaker.slash",
                                title: output.name,
                                description: output.isAvailable
                                    ? "Use software volume if this output does not support hardware volume control"
                                    : "Unavailable right now. FineTune will remember this output"
                            ) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { output.isEnabled },
                                        set: { onSoftwareVolumeToggle(output.uid, $0) }
                                    )
                                )
                                .toggleStyle(.switch)
                                .scaleEffect(0.8)
                                .labelsHidden()
                            }
                        }
                    }
                }
            }
        }
    }

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
                icon: "dial.medium",
                title: "Super Volume Keys",
                description: "Use your keyboard volume keys for outputs that use software volume",
                isOn: $settings.superVolumeKeysEnabled
            )

            if settings.superVolumeKeysEnabled && !accessibilityPermission.isGranted {
                accessibilityWarningRow
            }

            SettingsToggleRow(
                icon: "mic",
                title: "Lock Input Device",
                description: "Prevent auto-switching when devices connect",
                isOn: $settings.lockInputDevice
            )

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

    private var accessibilityWarningRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "hand.raised")
                .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access required")
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text("Enable in System Settings \u{2192} Privacy & Security \u{2192} Accessibility")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer()

            Button("Open") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(DesignTokens.Typography.pickerText)
        }
        .hoverableRow()
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

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

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Data")
                .padding(.bottom, DesignTokens.Spacing.xs)

            if showResetConfirmation {
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

    private var aboutFooter: some View {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
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
