// FineTune/Views/Components/EditablePercentage.swift
import SwiftUI
import AppKit

/// A percentage display that can be clicked to edit the value directly
/// Features a refined edit state with subtle visual feedback
struct EditablePercentage: View {
    @Binding var percentage: Int
    let range: ClosedRange<Int>
    var onCommit: ((Int) -> Void)? = nil
    /// True when this row is the popup's keyboard selection (gates keyboard entry).
    var isRowFocused: Bool = false

    @State private var isEditing = false
    @State private var inputText = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @State private var coordinator = ClickOutsideCoordinator()
    @State private var componentFrame: CGRect = .zero
    @Environment(PopupTextEntryCoordinator.self) private var textEntry: PopupTextEntryCoordinator?

    /// Popup-owned keyboard entry, so first responder never leaves the nav anchor.
    private var keyboardBuffer: String? {
        isRowFocused ? textEntry?.buffer : nil
    }
    private var isVisuallyEditing: Bool { isEditing || keyboardBuffer != nil }

    /// Text color adapts to state: accent when editing, secondary otherwise
    private var textColor: Color {
        isVisuallyEditing ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
    }

    var body: some View {
        HStack(spacing: 0) {
            if let buffer = keyboardBuffer {
                // No TextField for keyboard entry, so first responder stays on the nav anchor.
                Text(buffer)
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.trailing)
                Text("%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
            } else if isEditing {
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
        .padding(.horizontal, isVisuallyEditing ? 6 : 4)
        .padding(.vertical, isVisuallyEditing ? 2 : 1)
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
            if isVisuallyEditing {
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
                // Mouse edit released first responder; ask the popup to refocus the nav anchor.
                textEntry?.navRestoreNonce += 1
            }
        }
        .onChange(of: textEntry?.commitNonce) { _, _ in
            guard isRowFocused, let te = textEntry, let buffer = te.buffer else { return }
            if let value = Int(buffer), range.contains(value) {
                percentage = value
                onCommit?(value)
            }
            te.buffer = nil
        }
        .animation(.easeOut(duration: 0.15), value: isEditing)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func startEditing() {
        // A mouse edit supersedes any in-progress keyboard entry on this row.
        textEntry?.buffer = nil
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
        Task { @MainActor in
            isFocused = true
        }
    }

    private func commit() {
        let cleaned = inputText.replacing("%", with: "")
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
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Keyboard Entry Coordinator

/// Shared between the menu-bar popup and its rows. The popup owns keyboard percentage
/// entry — first responder never leaves the nav anchor — and writes `buffer`; the
/// keyboard-focused row's field renders it and commits when `commitNonce` changes. A
/// field raises `navRestoreNonce` when a *mouse* edit ends so the popup refocuses the anchor.
@MainActor
@Observable
final class PopupTextEntryCoordinator {
    var buffer: String? = nil
    var commitNonce: Int = 0
    var navRestoreNonce: Int = 0
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
