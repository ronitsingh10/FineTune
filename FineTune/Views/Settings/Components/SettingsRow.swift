// FineTune/Views/Settings/Components/SettingsRow.swift
import SwiftUI

@MainActor
struct SettingsRow<Trailing: View>: View {
    private let title: String
    private let description: String?
    @ViewBuilder private let trailing: () -> Trailing

    init(
        _ title: String,
        description: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(title))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                if let description {
                    Text(L10n.string(description))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Hairline divider sized to fit between `SettingsRow`s inside a
/// `SettingsSection`. Inset from the leading edge so it doesn't touch the
/// container border.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}
