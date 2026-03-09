// FineTune/Views/Components/ModeToggle.swift
import SwiftUI

/// A segmented control for switching between single and multi device modes
struct ModeToggle: View {
    @Binding var mode: DeviceSelectionMode

    @State private var hoveredOption: DeviceSelectionMode?
    @Environment(ThemeManager.self) private var theme

    private let options: [(mode: DeviceSelectionMode, label: String)] = [
        (.single, "Single"),
        (.multi, "Multi")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.mode) { option in
                optionButton(option.mode, label: option.label)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func optionButton(_ optionMode: DeviceSelectionMode, label: String) -> some View {
        let isSelected = mode == optionMode
        let isHovered = hoveredOption == optionMode

        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                mode = optionMode
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? theme.accentColor : DesignTokens.Colors.textTertiary)

                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs + 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius - 1)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .whenHovered { hovering in
            withAnimation(DesignTokens.Animation.hover) {
                hoveredOption = hovering ? optionMode : nil
            }
        }
    }
}

// MARK: - Previews

#Preview("Mode Toggle - Single Selected") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ModeToggle(mode: .constant(.single))
            ModeToggle(mode: .constant(.multi))
        }
        .frame(width: 180)
    }
}

#Preview("Mode Toggle Interactive") {
    struct InteractivePreview: View {
        @State private var mode: DeviceSelectionMode = .single

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    ModeToggle(mode: $mode)
                        .frame(width: 180)

                    Text("Current: \(mode == .single ? "Single" : "Multi")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
