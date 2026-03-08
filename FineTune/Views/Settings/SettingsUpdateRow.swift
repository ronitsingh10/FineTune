// FineTune/Views/Settings/SettingsUpdateRow.swift
import SwiftUI

/// Combined update settings row with toggle and manual check button (like Rectangle app)
struct SettingsUpdateRow: View {
    @Binding var automaticallyChecks: Bool
    let lastCheckDate: Date?
    let onCheckNow: () -> Void

    private var descriptionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let date = lastCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Version \(version) · Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
        return "Version \(version) · Never checked"
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Check for updates automatically")
                        .font(DesignTokens.Typography.rowName)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    Toggle("", isOn: $automaticallyChecks)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(DesignTokens.Colors.accentPrimary)
                        .labelsHidden()
                }

                Text(descriptionText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer()

            Button("Check for Updates") {
                onCheckNow()
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.pickerText)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .frame(width: DesignTokens.Dimensions.settingsPickerWidth)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(DesignTokens.Colors.pickerBackground)
            }
        }
        .hoverableRow()
    }
}

// MARK: - Preview

#Preview("Settings Update Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SettingsUpdateRow(
            automaticallyChecks: .constant(true),
            lastCheckDate: Date().addingTimeInterval(-120),
            onCheckNow: {}
        )

        SettingsUpdateRow(
            automaticallyChecks: .constant(false),
            lastCheckDate: nil,
            onCheckNow: {}
        )
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: DesignTokens.Dimensions.popupWidth)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
