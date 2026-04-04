// FineTune/Views/Components/ListeningModePicker.swift
import SwiftUI

struct ListeningModePicker: View {
    let availableModes: [ListeningMode]
    let currentMode: ListeningMode?
    let onSelectMode: (ListeningMode) -> Void

    var body: some View {
        if !availableModes.isEmpty {
            DropdownMenu(
                items: availableModes,
                selectedItem: currentMode,
                maxVisibleItems: nil,
                width: 80,
                popoverWidth: 180,
                onSelect: onSelectMode
            ) { selected in
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let mode = selected {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 10))
                        Text(mode.abbreviatedName)
                    } else {
                        Text("—")
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }
            } itemContent: { mode, isSelected in
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 11))
                        .frame(width: DesignTokens.Dimensions.iconSizeSmall)
                    Text(mode.displayName)
                        .lineLimit(1)
                    Spacer(minLength: DesignTokens.Spacing.xs)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignTokens.Colors.accentPrimary)
                    }
                }
            }
        }
    }
}

#Preview("AirPods Pro 2 — All Modes") {
    ComponentPreviewContainer {
        ListeningModePicker(
            availableModes: [.off, .noiseCancellation, .transparency, .adaptive],
            currentMode: .noiseCancellation,
            onSelectMode: { _ in }
        )
    }
}

#Preview("AirPods Max — No Adaptive") {
    ComponentPreviewContainer {
        ListeningModePicker(
            availableModes: [.off, .noiseCancellation, .transparency],
            currentMode: .transparency,
            onSelectMode: { _ in }
        )
    }
}

#Preview("AirPods Pro 3 — No Off") {
    ComponentPreviewContainer {
        ListeningModePicker(
            availableModes: [.noiseCancellation, .transparency, .adaptive],
            currentMode: .adaptive,
            onSelectMode: { _ in }
        )
    }
}

#Preview("No Modes Available") {
    ComponentPreviewContainer {
        ListeningModePicker(
            availableModes: [],
            currentMode: nil,
            onSelectMode: { _ in }
        )
    }
}
