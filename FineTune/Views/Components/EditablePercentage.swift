// FineTune/Views/Components/EditablePercentage.swift
import SwiftUI
import AppKit

/// A percentage display that can be clicked to edit the value directly
/// Features a refined edit state with subtle visual feedback
struct EditablePercentage: View {
    @Binding var percentage: Int
    let range: ClosedRange<Int>
    var onCommit: ((Int) -> Void)? = nil

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

                Text("%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
            } else {
                // Display mode: tappable percentage
                Text("\(percentage)%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : textColor)
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
        .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { startEditing() } }
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
        inputText = "\(percentage)"
        isEditing = true

        // Install monitors via coordinator (handles local, global, and app deactivation)
        coordinator.install(
            excludingFrame: componentFrame,
            onClickOutside: { [self] in
                cancel()
            }
        )

        // Delay focus to next runloop to ensure TextField is rendered
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func commit() {
        let cleaned = inputText.replacingOccurrences(of: "%", with: "")
                               .trimmingCharacters(in: .whitespaces)

        if let value = Int(cleaned), range.contains(value) {
            percentage = value
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
        @State private var percentage = 100

        var body: some View {
            HStack {
                Text("Volume:")
                EditablePercentage(percentage: $percentage, range: 0...400)
            }
            .padding()
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
