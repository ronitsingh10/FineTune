// FineTune/Views/Rows/AppEditRow.swift
import SwiftUI

/// Simplified app row shown in edit mode — icon, name, and visibility toggle.
/// Matches the glass row styling used by DeviceEditRow for visual consistency.
struct AppEditRow: View {
    let icon: NSImage
    let name: String
    let isIgnored: Bool
    let isPinned: Bool
    let onToggleVisibility: () -> Void
    let onTogglePin: () -> Void

    @State private var isEyeHovered = false
    @State private var isPinHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // App icon
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
                .opacity(isIgnored ? 0.4 : 1.0)

            // App name
            Text(name)
                .font(DesignTokens.Typography.rowName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isIgnored ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary)

            // Pin toggle
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
                .help(L10n.string(isPinned ? "Unpin app" : "Pin app"))
                .animation(DesignTokens.Animation.quick, value: isPinHovered)
            }

            // Eye toggle
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
            .help(L10n.string(isIgnored ? "Stop ignoring" : "Ignore app"))
            .animation(DesignTokens.Animation.quick, value: isEyeHovered)
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .hoverableRow()
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
