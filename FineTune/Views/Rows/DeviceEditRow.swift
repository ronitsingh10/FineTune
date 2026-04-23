// FineTune/Views/Rows/DeviceEditRow.swift
import SwiftUI
import AppKit

/// Priority-edit-mode row with drag handle, priority number, icon+name, and DEFAULT badge.
/// Icon+name+badge is the only tap region for expand — siblings keep their own gestures.
struct DeviceEditRow<ExpandedContent: View>: View {
    let device: AudioDevice
    let priorityIndex: Int
    let isDefault: Bool
    let isInputDevice: Bool
    let deviceCount: Int
    let isExpanded: Bool
    let onReorder: (Int) -> Void
    let onToggleExpand: () -> Void
    @ViewBuilder let expandedContent: () -> ExpandedContent

    @State private var isInfoButtonHovered = false

    var body: some View {
        ExpandableGlassRow(isExpanded: isExpanded) {
            headerRow
        } expandedContent: {
            expandedContent()
        }
    }

    private var infoButtonColor: Color {
        if isExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isInfoButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    private var headerRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(width: 16)

            EditablePriority(
                index: priorityIndex,
                count: deviceCount,
                onReorder: onReorder
            )

            HStack(spacing: DesignTokens.Spacing.sm) {
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

                Text(device.name)
                    .font(isDefault ? DesignTokens.Typography.rowNameBold : DesignTokens.Typography.rowName)
                    .lineLimit(1)
                    .help(device.uid)

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

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isExpanded ? "Collapse device details" : "Expand device details")

            infoButton
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
    }

    private var infoButton: some View {
        Button {
            onToggleExpand()
        } label: {
            ZStack {
                Image(systemName: "info.circle")
                    .opacity(isExpanded ? 0 : 1)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Image(systemName: "xmark")
                    .opacity(isExpanded ? 1 : 0)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .font(.system(size: 12))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(infoButtonColor)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isInfoButtonHovered = $0 }
        .help(isExpanded ? "Close device inspector" : "Device inspector")
        .accessibilityLabel(isExpanded ? "Close device inspector" : "Open device inspector")
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isExpanded)
        .animation(DesignTokens.Animation.hover, value: isInfoButtonHovered)
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

// MARK: - Previews

#Preview("DeviceEditRow Tap Carveout") {
    DeviceEditRowTapCarveoutPreview()
}

struct DeviceEditRowTapCarveoutPreview: View {
    @State private var lastEvent: String = "Tap anywhere to test"
    @State private var expandedUID: String?

    var body: some View {
        PreviewContainer {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text(lastEvent)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                DeviceEditRow(
                    device: MockData.sampleDevices[0],
                    priorityIndex: 0,
                    isDefault: true,
                    isInputDevice: false,
                    deviceCount: 3,
                    isExpanded: expandedUID == MockData.sampleDevices[0].uid,
                    onReorder: { newIndex in
                        lastEvent = "Reorder to \(newIndex + 1)"
                    },
                    onToggleExpand: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            let uid = MockData.sampleDevices[0].uid
                            expandedUID = (expandedUID == uid) ? nil : uid
                            lastEvent = "Toggled expand → \(expandedUID ?? "nil")"
                        }
                    },
                    expandedContent: {
                        Text("Expanded detail content here")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                )
            }
        }
    }
}
