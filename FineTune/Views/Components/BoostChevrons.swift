// FineTune/Views/Components/BoostChevrons.swift
import SwiftUI

/// Stacked chevron boost indicator — 3 SF Symbol chevrons that light up based on boost level.
/// Click to cycle: 1x → 2x → 3x → 4x → 1x
struct BoostChevrons: View {
    let level: BoostLevel
    let onTap: () -> Void

    @State private var isHovered = false

    /// Number of lit chevrons for each boost level
    private var litCount: Int {
        switch level {
        case .x1: 0
        case .x2: 1
        case .x3: 2
        case .x4: 3
        }
    }

    /// Color for each chevron position (bottom=0, top=2)
    private func chevronColor(at index: Int) -> Color {
        if index < litCount {
            return DesignTokens.Colors.accentPrimary
        } else {
            return isHovered
                ? .primary.opacity(0.25)
                : .primary.opacity(0.15)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: -2) {
                ForEach((0..<3).reversed(), id: \.self) { index in
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(chevronColor(at: index))
                }
            }
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L10n.format("Volume boost: %@", level.label))
        .accessibilityLabel(L10n.format("Volume boost %@", level.label))
        .animation(.snappy(duration: 0.2), value: level)
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}

// MARK: - Previews

#Preview("Boost Chevrons") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                BoostChevrons(level: .x1, onTap: {})
                Text("1x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x2, onTap: {})
                Text("2x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x3, onTap: {})
                Text("3x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x4, onTap: {})
                Text("4x").font(.caption)
            }
        }
    }
}
