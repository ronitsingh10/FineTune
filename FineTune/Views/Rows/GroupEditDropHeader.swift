// FineTune/Views/Rows/GroupEditDropHeader.swift
import SwiftUI

/// Edit-mode group header: rename, delete, and drop target for dragging apps in.
struct GroupEditDropHeader: View {
    let group: AppGroup
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onDropApp: (String) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 12))
                .foregroundStyle(
                    isDropTargeted
                        ? DesignTokens.Colors.accentPrimary
                        : DesignTokens.Colors.textSecondary
                )

            TextField(
                "Group name",
                text: Binding(
                    get: { group.name },
                    set: onRename
                )
            )
            .textFieldStyle(.plain)
            .font(DesignTokens.Typography.rowName)

            Text("\(group.members.count)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .monospacedDigit()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(
                        minWidth: DesignTokens.Dimensions.minTouchTarget,
                        minHeight: DesignTokens.Dimensions.minTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete group")
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(
                    isDropTargeted
                        ? DesignTokens.Colors.accentPrimary.opacity(0.15)
                        : DesignTokens.Colors.hoverSurface.opacity(0.5)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .strokeBorder(
                    isDropTargeted ? DesignTokens.Colors.accentPrimary.opacity(0.6) : Color.clear,
                    lineWidth: 1.5
                )
        }
        .dropDestination(for: String.self, action: { items, _ in
            guard let identifier = items.first else { return false }
            onDropApp(identifier)
            return true
        }, isTargeted: { targeted in
            isDropTargeted = targeted
        })
        .help("Drop apps here to add them to this group")
    }
}
