// FineTune/Views/Settings/SettingsToggleRow.swift
import SwiftUI

/// Settings row with a toggle switch control
struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let description: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRowView(icon: icon, title: title, description: description) {
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
            icon: "sparkles",
            title: "Enable Effects",
            description: "Apply processing effects in the app",
            isOn: .constant(false)
        )
    }
    .padding()
    .frame(width: 400)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
