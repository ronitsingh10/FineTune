// FineTune/Views/Settings/SettingsRowView.swift
import SwiftUI

/// Base component for settings rows with icon, title, description, and control slot
struct SettingsRowView<Control: View>: View {
    let icon: String
    let titleOffsetX: CGFloat
    let title: String
    let description: String?
    @ViewBuilder let control: () -> Control

    init(
        icon: String,
        titleOffsetX: CGFloat = 0,
        title: String,
        description: String?,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.icon = icon
        self.titleOffsetX = titleOffsetX
        self.title = title
        self.description = description
        self.control = control
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Dimensions.iconSizeSmall))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)

            // Title + Description
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                if let description {
                    Text(description)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(2)
                }
            }
            .offset(x: titleOffsetX)

            Spacer(minLength: DesignTokens.Spacing.sm)

            // Control
            control()
        }
        .hoverableRow()
    }
}

// MARK: - Previews

#Preview("Settings Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SettingsRowView(
            icon: "power",
            title: "Launch at Login",
            description: "Start FineTune when you log in"
        ) {
            Toggle("", isOn: .constant(true))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }

        SettingsRowView(
            icon: "speaker.wave.2",
            title: "Default Volume",
            description: nil
        ) {
            Text("100%")
                .font(DesignTokens.Typography.percentage)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }
    .padding()
    .frame(width: 400)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
