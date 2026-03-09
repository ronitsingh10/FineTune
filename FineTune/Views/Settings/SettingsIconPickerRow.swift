// FineTune/Views/Settings/SettingsIconPickerRow.swift
import SwiftUI

/// Settings row with visual icon selector for menu bar icon style
struct SettingsIconPickerRow: View {
    let icon: String
    let title: String
    @Binding var selection: MenuBarIconStyle
    let appliedStyle: MenuBarIconStyle

    /// Whether a restart is needed to apply the selected icon
    private var needsRestart: Bool {
        selection != appliedStyle
    }

    @Environment(ThemeManager.self) private var theme

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text(needsRestart ? "Restart to apply changes" : "Choose your preferred icon style")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer()

            // Restart button when needed
            if needsRestart {
                Button("Restart") {
                    restartApp()
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(theme.accentColor)
            }

            // Icon options on the right
            HStack(spacing: 4) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    IconOption(style: style, isSelected: selection == style) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection = style
                        }
                    }
                }
            }
        }
        .hoverableRow()
    }

    /// Relaunches the app to apply icon changes
    private func restartApp() {
        let url = Bundle.main.bundleURL

        // Use shell to wait for app to quit, then relaunch
        let script = """
            sleep 0.5
            open "\(url.path)"
            """

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        try? task.run()

        // Quit the app
        NSApplication.shared.terminate(nil)
    }
}

/// Individual icon option button (compact for inline display)
private struct IconOption: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(ThemeManager.self) private var theme

    var body: some View {
        Button(action: onSelect) {
            Group {
                if style.isSystemSymbol {
                    Image(systemName: style.iconName)
                        .font(.system(size: 14))
                } else {
                    Image(style.iconName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
            }
            .foregroundStyle(isSelected ? theme.accentColor : DesignTokens.Colors.textSecondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.accentColor.opacity(0.15) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? theme.accentColor : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Icon Picker Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        // No restart needed (same selection as applied)
        SettingsIconPickerRow(
            icon: "menubar.rectangle",
            title: "Menu Bar Icon",
            selection: .constant(.default),
            appliedStyle: .default
        )

        // Restart needed (different selection)
        SettingsIconPickerRow(
            icon: "menubar.rectangle",
            title: "Menu Bar Icon",
            selection: .constant(.speaker),
            appliedStyle: .default
        )
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: DesignTokens.Dimensions.popupWidth)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
