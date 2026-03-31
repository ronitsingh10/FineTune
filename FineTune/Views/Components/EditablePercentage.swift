// FineTune/Views/Components/EditablePercentage.swift
import SwiftUI
import AppKit

/// A percentage display that can be clicked to edit the value directly
/// Features a refined edit state with subtle visual feedback
struct EditablePercentage: View {
    @Binding var sliderValue: Double
    let range: ClosedRange<Double>
    let useLogScale: Bool
    var onCommit: ((Double) -> Void)? = nil

    @State private var isEditing = false
    @State private var inputText = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @State private var coordinator = ClickOutsideCoordinator()
    @State private var componentFrame: CGRect = .zero

    /// Text color adapts to state: accent when editing, secondary otherwise
    private var textColor: Color {
        isEditing ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
    }

    private var width: CGFloat {
        if useLogScale {
            DesignTokens.Dimensions.decibelsWidth
        } else {
            DesignTokens.Dimensions.percentageWidth
        }
    }

    private var percentage: Int { Int(sliderValue * 100) }

    private var decibels: String {
        let gain = VolumeMapping.sliderToGain(sliderValue, logScale: useLogScale)
        let db = VolumeMapping.gainToDecibels(gain)
        return String(format: "%0.1f", db)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                // Edit mode: TextField + fixed "%" suffix
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .fixedSize()  // Size to content

                if !useLogScale {
                    Text("%")
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(textColor)
                }
            } else {
                // Display mode: tappable percentage
                if useLogScale {
                    Text(decibels)
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : textColor)
                } else {
                    Text("\(percentage)%")
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : textColor)
                }
            }
        }
        .padding(.horizontal, isEditing ? 6 : 4)
        .padding(.vertical, isEditing ? 2 : 1)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: FramePreferenceKey.self, value: geo.frame(in: .global))
            }
        }
        .onPreferenceChange(FramePreferenceKey.self) { frame in
            updateScreenFrame(from: frame)
        }
        .background {
            if isEditing {
                // Subtle pill background when editing
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    }
            } else if isHovered {
                // Subtle hover background to indicate clickability
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: width, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { startEditing() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Edit volume percentage")
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                coordinator.removeMonitors()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isEditing)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func startEditing() {
        if useLogScale {
            inputText = decibels
        } else {
            inputText = "\(percentage)"
        }
        isEditing = true

        // Install monitors via coordinator (handles local, global, and app deactivation)
        coordinator.install(
            excludingFrame: componentFrame,
            onClickOutside: { [self] in
                cancel()
            }
        )

        // Delay focus to next runloop to ensure TextField is rendered
        Task { @MainActor in
            isFocused = true
        }
    }

    private func parseValue(_ input: String) -> Double? {
        let cleaned = input
            .replacing("%", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let newValue = Float(cleaned) else { return nil }

        if useLogScale {
            let gain = VolumeMapping.decibelsToGain(Double(newValue))
            return VolumeMapping.gainToSlider(gain, logScale: useLogScale)
        } else {
            return Double(newValue) / 100
        }
    }

    private func commit() {
        if let value = parseValue(inputText), range.contains(value) {
            sliderValue = value
            onCommit?(value)
        }
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }

    private func updateScreenFrame(from globalFrame: CGRect) {
        componentFrame = screenFrame(from: globalFrame)
    }
}

// MARK: - Preference Key for Frame Tracking

private struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Previews

#Preview("Editable Percentage") {
    struct PreviewWrapper: View {
        @State private var value: Double = 1.0

        var body: some View {
            HStack {
                Text("Volume:")
                EditablePercentage(
                    sliderValue: $value,
                    range: 0...1,
                    useLogScale: false
                )
            }
            .padding()
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
