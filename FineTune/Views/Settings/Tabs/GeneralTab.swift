// FineTune/Views/Settings/Tabs/GeneralTab.swift
import SwiftUI

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let onResetAll: () -> Void
    var controlFailure: String? = nil

    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                generalSection
                menuBarSection
                dataSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { onResetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection("General") {
            SettingsRow(
                "Launch at Login",
                description: "Start FineTune when you log in"
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "External controller access",
                description: "Allow apps running as your user to read and control FineTune. Uses a local socket."
            ) {
                Toggle("", isOn: $settings.appSettings.externalControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if let controlFailure {
                Text(controlFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            SettingsRowDivider()
            SettingsRow(
                "Theme",
                description: "Match macOS, or lock to Light or Dark"
            ) {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
            SettingsRowDivider()
            SettingsRow(
                "Device Disconnect Alerts",
                description: "Show notification when an audio device disconnects"
            ) {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarSection: some View {
        SettingsSection("Menu Bar") {
            SettingsRow(
                "Icon Style",
                description: "How FineTune appears in your menu bar"
            ) {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(
                "Popup Size",
                description: "Smaller fits more on screen; larger leaves more breathing room."
            ) {
                PopupSizeTilePicker(selection: $settings.appSettings.popupSize)
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection("Data") {
            SettingsRow(
                "Reset All Settings",
                description: "Clear all volumes, EQ, and device routings"
            ) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }
}
