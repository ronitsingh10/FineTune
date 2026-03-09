// FineTune/Views/Components/ExpandableGlassRow.swift
import SwiftUI

/// A reusable expandable row with Liquid Glass styling.
/// Border colours are driven by ThemeManager:
///   Hi-contrast → standard grey separator borders.
///   Lo-contrast → soft primary-tinted borders.
struct ExpandableGlassRow<Header: View, ExpandedContent: View>: View {
    let isExpanded: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let expandedContent: () -> ExpandedContent

    @State private var isHovered = false
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header()

            if isExpanded {
                expandedContent()
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                            removal:   .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                        )
                    )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(isHovered ? Color.white.opacity(0.04) : Color.clear)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .strokeBorder(
                    isHovered ? theme.cellBorderHoverColor : theme.cellBorderColor,
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}
