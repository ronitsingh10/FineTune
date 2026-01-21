// FineTune/Views/SettingsView.swift
import SwiftUI

/// Settings view with tabbed interface
struct SettingsView: View {
    @Binding var isPresented: Bool
    var settingsManager: SettingsManager
    var updateChecker: UpdateChecker
    var currentMenuBarIcon: MenuBarIconOption
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case about = "About"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // Header with close button
            HStack {
                Text("Settings")
                    .sectionHeaderStyle()
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .iconButtonStyle()
            }

            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Tab content
            switch selectedTab {
            case .general:
                GeneralTabView(settingsManager: settingsManager, currentMenuBarIcon: currentMenuBarIcon)
            case .about:
                AboutTabView(updateChecker: updateChecker, settingsManager: settingsManager)
            }

            Spacer()
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: DesignTokens.Dimensions.popupWidth)
        .darkGlassBackground()
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - General Tab

/// General settings tab with appearance options
struct GeneralTabView: View {
    var settingsManager: SettingsManager
    var currentMenuBarIcon: MenuBarIconOption
    @State private var selectedIcon: MenuBarIconOption
    @State private var startAtLogin: Bool

    init(settingsManager: SettingsManager, currentMenuBarIcon: MenuBarIconOption) {
        self.settingsManager = settingsManager
        self.currentMenuBarIcon = currentMenuBarIcon
        _selectedIcon = State(initialValue: settingsManager.appPreferences.menuBarIcon)
        _startAtLogin = State(initialValue: settingsManager.startAtLogin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            // Startup section
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Startup")
                    .font(DesignTokens.Typography.rowNameBold)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Toggle("Start at login", isOn: $startAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: startAtLogin) { _, newValue in
                        settingsManager.startAtLogin = newValue
                    }
            }

            Divider()

            // Appearance section
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Appearance")
                    .font(DesignTokens.Typography.rowNameBold)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                // Menu Bar Icon picker
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Menu Bar Icon")
                        .font(DesignTokens.Typography.rowName)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)

                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ForEach(MenuBarIconOption.allCases, id: \.self) { option in
                            MenuBarIconButton(
                                option: option,
                                isSelected: selectedIcon == option,
                                onSelect: {
                                    selectedIcon = option
                                    settingsManager.setMenuBarIcon(option)
                                }
                            )
                        }
                    }

                    // Show relaunch button if icon changed
                    if selectedIcon != currentMenuBarIcon {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text("Restart required to apply")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textTertiary)

                            Button("Relaunch") {
                                relaunchApp()
                            }
                            .buttonStyle(.plain)
                            .font(DesignTokens.Typography.caption)
                            .glassButtonStyle()
                        }
                        .padding(.top, DesignTokens.Spacing.xs)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Relaunches the app to apply icon changes
    private func relaunchApp() {
        // Flush settings to ensure the new icon is persisted
        settingsManager.flushSync()

        // Get the app's bundle URL
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }

        // Launch a new instance of the app
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if error == nil {
                // Terminate the current instance after the new one launches
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

/// Button for selecting a menu bar icon option
private struct MenuBarIconButton: View {
    let option: MenuBarIconOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Group {
                    if option.isSystemImage {
                        Image(systemName: option.imageName)
                    } else {
                        Image(option.imageName)
                            .renderingMode(.template)
                    }
                }
                .font(.system(size: 18))
                .frame(width: 32, height: 24)

                Text(option.displayName)
                    .font(DesignTokens.Typography.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .frame(minWidth: 56)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.3) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DesignTokens.Colors.accentPrimary : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
    }
}

// MARK: - About Tab

/// About tab showing app info, update status, author, and GitHub link
struct AboutTabView: View {
    var updateChecker: UpdateChecker
    var settingsManager: SettingsManager

    @State private var autoCheckForUpdates: Bool

    init(updateChecker: UpdateChecker, settingsManager: SettingsManager) {
        self.updateChecker = updateChecker
        self.settingsManager = settingsManager
        _autoCheckForUpdates = State(initialValue: settingsManager.autoCheckForUpdates)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            // App icon and name
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)

                Text("FineTune")
                    .font(DesignTokens.Typography.rowNameBold)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Version \(appVersion) (\(buildNumber))")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            // Description
            Text("Per-application audio control for macOS")
                .font(DesignTokens.Typography.rowName)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)

            // Update status section
            updateStatusSection

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Author info
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text("Created by")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                Text("Ronit Singh")
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            // GitHub link
            Button {
                if let url = URL(string: "https://github.com/ronitsingh10/FineTune") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("View on GitHub", systemImage: "link")
                    .font(DesignTokens.Typography.caption)
            }
            .buttonStyle(.plain)
            .glassButtonStyle()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: - Update Status Section

    @ViewBuilder
    private var updateStatusSection: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            // Status indicator
            HStack(spacing: DesignTokens.Spacing.sm) {
                updateStatusIcon
                updateStatusText
            }

            // Action buttons
            HStack(spacing: DesignTokens.Spacing.sm) {
                if case .updateAvailable = updateChecker.status {
                    Button {
                        updateChecker.openReleasePage()
                    } label: {
                        Label("Download Update", systemImage: "arrow.down.circle")
                            .font(DesignTokens.Typography.caption)
                    }
                    .buttonStyle(.plain)
                    .glassButtonStyle()
                }

                if case .checking = updateChecker.status {
                    // Show nothing while checking (progress indicator shows status)
                } else {
                    Button {
                        Task {
                            settingsManager.recordUpdateCheck()
                            await updateChecker.checkForUpdates()
                        }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                            .font(DesignTokens.Typography.caption)
                    }
                    .buttonStyle(.plain)
                    .glassButtonStyle()
                }
            }

            // Auto-check toggle
            Toggle("Check for updates automatically", isOn: $autoCheckForUpdates)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .onChange(of: autoCheckForUpdates) { _, newValue in
                    settingsManager.autoCheckForUpdates = newValue
                }
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignTokens.Colors.recessedBackground)
        )
    }

    @ViewBuilder
    private var updateStatusIcon: some View {
        switch updateChecker.status {
        case .idle:
            Image(systemName: "info.circle")
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .updateAvailable:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(DesignTokens.Colors.accentPrimary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var updateStatusText: some View {
        switch updateChecker.status {
        case .idle:
            Text("Click to check for updates")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        case .checking:
            Text("Checking for updates...")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        case .upToDate:
            Text("You're up to date")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        case let .updateAvailable(info):
            Text("Version \(info.version.description) available")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
        case let .error(message):
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Previews

#Preview("Settings View") {
    SettingsView(
        isPresented: .constant(true),
        settingsManager: SettingsManager(),
        updateChecker: UpdateChecker(),
        currentMenuBarIcon: .default
    )
}

#Preview("General Tab") {
    PreviewContainer {
        GeneralTabView(settingsManager: SettingsManager(), currentMenuBarIcon: .default)
    }
}

#Preview("About Tab") {
    PreviewContainer {
        AboutTabView(updateChecker: UpdateChecker(), settingsManager: SettingsManager())
    }
}
