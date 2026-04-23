// FineTune/Views/Rows/DeviceEditRow.swift
import SwiftUI
import AppKit

/// Simplified device row for priority edit mode.
/// Shows drag handle, priority number, device icon + name, DEFAULT badge, hide toggle, and UID copy button.
struct DeviceEditRow: View {
    let device: AudioDevice
    let priorityIndex: Int
    let isDefault: Bool
    let isInputDevice: Bool
    let deviceCount: Int
    let onReorder: (Int) -> Void

    let isHidden: Bool
    let onToggleHidden: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(width: 16)

            // Editable priority number
            EditablePriority(
                index: priorityIndex,
                count: deviceCount,
                onReorder: onReorder
            )

            // Device icon
            Group {
                if let icon = device.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: isInputDevice ? "mic" : "speaker.wave.2")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)

            // Device name
            Text(device.name)
                .font(isDefault ? DesignTokens.Typography.rowNameBold : DesignTokens.Typography.rowName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(device.uid)

            // DEFAULT badge
            if isDefault {
                Text("DEFAULT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.1))
                    )
            }

            // Hide/show toggle button
            // Disabled for the current default device — it stays visible while it's the default.
            Button {
                onToggleHidden()
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isDefault
                            ? DesignTokens.Colors.textTertiary.opacity(0.4)
                            : (isHidden ? DesignTokens.Colors.mutedIndicator : DesignTokens.Colors.textTertiary)
                    )
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(isDefault)
            .help(isDefault
                ? "Cannot hide the default device"
                : (isHidden ? "Show in main view" : "Hide from main view")
            )

            // Copy UID button (always at far right)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.uid, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? .green : DesignTokens.Colors.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("Copy UID")
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .opacity(isHidden && !isDefault ? 0.5 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHidden)
        .hoverableRow()
    }
}

// MARK: - Editable Priority Number

/// Inline editable priority number — click to type a new position.
/// Same interaction pattern as `EditablePercentage` but displays just a number.
private struct EditablePriority: View {
    let index: Int
    let count: Int
    let onReorder: (Int) -> Void

    @State private var isEditing = false
    @State private var inputText = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @State private var coordinator = ClickOutsideCoordinator()
    @State private var componentFrame: CGRect = .zero

    /// Display number is 1-based
    private var displayNumber: Int { index + 1 }

    private var textColor: Color {
        isEditing ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.center)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .fixedSize()
            } else {
                Text("\(displayNumber)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : textColor)
            }
        }
        .padding(.horizontal, isEditing ? 4 : 2)
        .padding(.vertical, isEditing ? 2 : 1)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: PriorityFrameKey.self, value: geo.frame(in: .global))
            }
        }
        .onPreferenceChange(PriorityFrameKey.self) { frame in
            updateScreenFrame(from: frame)
        }
        .background {
            if isEditing {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    }
            } else if isHovered {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: 16, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { startEditing() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Edit priority position")
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
        inputText = "\(displayNumber)"
        isEditing = true

        coordinator.install(
            excludingFrame: componentFrame,
            onClickOutside: { [self] in
                cancel()
            }
        )

        Task { @MainActor in
            isFocused = true
        }
    }

    private func commit() {
        let cleaned = inputText.trimmingCharacters(in: .whitespaces)
        if let value = Int(cleaned), (1...count).contains(value) {
            let newIndex = value - 1
            if newIndex != index {
                onReorder(newIndex)
            }
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

// MARK: - Preference Key

private struct PriorityFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
