// FineTune/Views/Settings/Components/HUDStyleSegmentedControl.swift
import SwiftUI

/// Compact thumbnail picker for `HUDStyle`. Mirrors the existing
/// `HUDStylePicker` thumbnails (Tahoe pill, Classic square + ticks) but
/// drops the title/description chrome so it fits a `CardRow` trailing slot.
@MainActor
struct HUDStyleSegmentedControl: View {
    @Binding var selection: HUDStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HUDStyle.allCases) { style in
                HUDStyleOption(style: style, isSelected: selection == style) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        selection = style
                    }
                }
            }
        }
    }
}

private struct HUDStyleOption: View {
    let style: HUDStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            thumbnail
                .frame(width: 52, height: 22)
                .frame(width: 60, height: 26)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.15) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? DesignTokens.Colors.accentPrimary : Color.clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.displayName)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch style {
        case .tahoe: tahoeThumbnail
        case .classic: classicThumbnail
        }
    }

    private var tahoeThumbnail: some View {
        let tint = isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.5), lineWidth: 0.75)
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(tint.opacity(0.7))
                        .frame(width: 3, height: 3)
                    Capsule()
                        .fill(tint.opacity(0.35))
                        .frame(height: 1.5)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(tint)
                                .frame(width: 14, height: 1.5)
                        }
                }
                .padding(.horizontal, 5)
            }
    }

    private var classicThumbnail: some View {
        let tint = isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(0.08))
            .frame(width: 22, height: 22)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(tint.opacity(0.5), lineWidth: 0.75)
            }
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(tint.opacity(0.8))
                    HStack(spacing: 1) {
                        ForEach(0..<4) { idx in
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill(idx < 2 ? tint : tint.opacity(0.3))
                                .frame(width: 2, height: 2)
                        }
                    }
                }
            }
    }
}
