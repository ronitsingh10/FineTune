// FineTune/Views/Rows/AppEditRow.swift
import AppKit
import SwiftUI

/// Simplified app row shown in edit mode — icon, name, pin/visibility, optional drag.
struct AppEditRow: View {
    let icon: NSImage
    let name: String
    let isIgnored: Bool
    let isPinned: Bool
    let onToggleVisibility: () -> Void
    let onTogglePin: () -> Void
    /// When set, the row can be dragged onto a group drop target.
    var dragIdentifier: String? = nil

    @State private var isEyeHovered = false
    @State private var isPinHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if dragIdentifier != nil {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(width: 12)
            }

            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
                .opacity(isIgnored ? 0.4 : 1.0)

            Text(name)
                .font(DesignTokens.Typography.rowName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isIgnored ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary)

            if !isIgnored {
                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(pinColor)
                        .frame(
                            minWidth: DesignTokens.Dimensions.minTouchTarget,
                            minHeight: DesignTokens.Dimensions.minTouchTarget
                        )
                        .contentShape(Rectangle())
                        .scaleEffect(isPinHovered ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { isPinHovered = $0 }
                .help(isPinned ? "Unpin app" : "Pin app")
                .animation(DesignTokens.Animation.quick, value: isPinHovered)
            }

            Button {
                onToggleVisibility()
            } label: {
                Image(systemName: isIgnored ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(eyeColor)
                    .frame(
                        minWidth: DesignTokens.Dimensions.minTouchTarget,
                        minHeight: DesignTokens.Dimensions.minTouchTarget
                    )
                    .contentShape(Rectangle())
                    .scaleEffect(isEyeHovered ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { isEyeHovered = $0 }
            .help(isIgnored ? "Stop ignoring" : "Ignore app")
            .animation(DesignTokens.Animation.quick, value: isEyeHovered)
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .hoverableRow()
        .modifier(OptionalAppDragModifier(identifier: dragIdentifier, previewName: name))
    }

    private var pinColor: Color {
        if isPinned {
            return isPinHovered ? DesignTokens.Colors.accentPrimary.opacity(0.8) : DesignTokens.Colors.accentPrimary
        } else {
            return isPinHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault
        }
    }

    private var eyeColor: Color {
        if isIgnored {
            return isEyeHovered ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
        } else {
            return isEyeHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault
        }
    }
}

/// Applies `.draggable` only when an identifier is present.
private struct OptionalAppDragModifier: ViewModifier {
    let identifier: String?
    let previewName: String

    func body(content: Content) -> some View {
        if let identifier {
            content.draggable(identifier) {
                HStack(spacing: 6) {
                    Image(systemName: "app.fill")
                    Text(previewName)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            content
        }
    }
}
