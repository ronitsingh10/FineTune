// FineTune/Views/Components/RadioButton.swift
import SwiftUI

/// A radio-style button for selecting default device
struct RadioButton: View {
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .symbolRenderingMode(isSelected ? .monochrome : .hierarchical)
                .foregroundStyle(isSelected ? DesignTokens.Colors.defaultDevice : buttonColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isSelected ? "Default device" : "Set as default")
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }

    private var buttonColor: Color {
        isHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault
    }
}

// MARK: - Previews

#Preview("Radio Buttons") {
    ComponentPreviewContainer {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                RadioButton(isSelected: true) {}
                Text("MacBook Pro Speakers")
            }

            HStack {
                RadioButton(isSelected: false) {}
                Text("AirPods Pro")
            }

            HStack {
                RadioButton(isSelected: false) {}
                Text("External Display")
            }
        }
    }
}
