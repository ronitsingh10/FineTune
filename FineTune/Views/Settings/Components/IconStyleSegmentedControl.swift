// FineTune/Views/Settings/Components/IconStyleSegmentedControl.swift
import SwiftUI

/// Compact segmented selector for `MenuBarIconStyle`. Lifted out of the
/// previous `SettingsIconPickerRow` so it can drop into a `CardRow`'s
/// trailing slot without dragging row chrome along with it.
@MainActor
struct IconStyleSegmentedControl: View {
    @Binding var selection: MenuBarIconStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuBarIconStyle.allCases) { style in
                IconOption(style: style, isSelected: selection == style) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        selection = style
                    }
                }
            }
        }
    }
}

private struct IconOption: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Group {
                if style.isSystemSymbol {
                    Image(systemName: style.iconName)
                        .font(.system(size: 14))
                } else {
                    Image(style.iconName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
            }
            .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
            .frame(width: 30, height: 30)
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
}

// MARK: - Previews

#Preview("Icon Style Segmented Control") {
    VStack(spacing: 16) {
        IconStyleSegmentedControl(selection: .constant(.default))
        IconStyleSegmentedControl(selection: .constant(.speaker))
        IconStyleSegmentedControl(selection: .constant(.equalizer))
    }
    .padding()
    .frame(width: 300)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
