// FineTune/Views/Components/ExpandableGlassRow.swift
import SwiftUI

/// A reusable expandable row with Liquid Glass styling
/// The glass container grows/shrinks smoothly during expansion using SwiftUI's natural height calculation
struct ExpandableGlassRow<Header: View, ExpandedContent: View>: View {
    let isExpanded: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let expandedContent: ExpandedContent

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Header content - always visible
            header

            // Expandable content - conditional rendering lets SwiftUI calculate natural height
            if isExpanded {
                expandedContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                        )
                    )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        // Flat at rest, hover reveals hoverSurface (System Settings pattern).
        // An open panel keeps the same fill so the active row reads at a glance.
        // The 1pt vertical inset on the fill keeps adjacent active rows
        // visually separated when two are simultaneously lit (e.g. an
        // expanded row with a hovered neighbour).
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(isHovered || isExpanded ? DesignTokens.Colors.hoverSurface : Color.clear)
                .padding(.vertical, 1)
                .allowsHitTesting(false)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        // NOTE: Do NOT add .animation(_, value: isExpanded) here!
        // Animation is handled by the caller via withAnimation in onEQToggle.
        // Adding animation here causes layout loops with conditional content rendering.
        // The hoverSurface fill flips with isExpanded under that same caller
        // animation, so it cross-fades smoothly without an explicit modifier.
    }
}

// MARK: - Previews

#Preview("Expandable Glass Row - Collapsed") {
    PreviewContainer {
        ExpandableGlassRow(isExpanded: false) {
            HStack {
                Image(systemName: "music.note")
                Text("Spotify")
                Spacer()
                Text("75%")
                    .foregroundStyle(.secondary)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            VStack {
                Text("Expanded Content")
                    .padding()
            }
            .frame(height: 100)
            .background(DesignTokens.Colors.recessedBackground)
        }
    }
}

#Preview("Expandable Glass Row - Expanded") {
    PreviewContainer {
        ExpandableGlassRow(isExpanded: true) {
            HStack {
                Image(systemName: "music.note")
                Text("Spotify")
                Spacer()
                Text("75%")
                    .foregroundStyle(.secondary)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            VStack(spacing: 8) {
                Text("EQ Panel Content")
                HStack(spacing: 16) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.secondary)
                            .frame(width: 4, height: 60)
                    }
                }
            }
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)
        }
    }
}
