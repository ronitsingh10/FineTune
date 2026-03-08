// FineTune/Views/Settings/SettingsToggleRow.swift
import SwiftUI

/// Settings row with a toggle switch control
struct SettingsToggleRow: View {
    let icon: String
    let titleOffsetX: CGFloat
    let title: String
    let description: String?
    @Binding var isOn: Bool

    init(
        icon: String,
        titleOffsetX: CGFloat = 0,
        title: String,
        description: String?,
        isOn: Binding<Bool>
    ) {
        self.icon = icon
        self.titleOffsetX = titleOffsetX
        self.title = title
        self.description = description
        self._isOn = isOn
    }

    var body: some View {
        SettingsRowView(icon: icon, titleOffsetX: titleOffsetX, title: title, description: description) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
    }
}

// MARK: - Previews

#Preview("Toggle Rows") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SettingsToggleRow(
            icon: "power",
            title: "Launch at Login",
            description: "Start FineTune when you log in",
            isOn: .constant(true)
        )

        SettingsToggleRow(
            icon: "bell",
            title: "Device Disconnect Alerts",
            description: "Show notification when device disconnects",
            isOn: .constant(false)
        )
    }
    .padding()
    .frame(width: 400)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
