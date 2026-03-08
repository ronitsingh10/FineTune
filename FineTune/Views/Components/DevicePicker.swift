// FineTune/Views/Components/DevicePicker.swift
import SwiftUI

/// A styled device picker dropdown with "System" option and single/multi mode support
struct DevicePicker: View {
    let devices: [AudioDevice]
    let selectedDeviceUID: String  // For single mode
    let selectedDeviceUIDs: Set<String>  // For multi mode
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let mode: DeviceSelectionMode
    let onModeChange: (DeviceSelectionMode) -> Void
    let onDeviceSelected: (String) -> Void  // Single mode callback
    let onDevicesSelected: (Set<String>) -> Void  // Multi mode callback
    let onSelectFollowDefault: () -> Void
    let showModeToggle: Bool

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    // Local state mirrors props for popover reactivity
    @State private var currentMode: DeviceSelectionMode = .single
    @State private var currentSelectedUIDs: Set<String> = []

    // Configuration
    private let triggerWidth: CGFloat = 128
    private let popoverWidth: CGFloat = 210
    private let itemHeight: CGFloat = 26
    private let itemSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 8

    /// Menu item representation for unified dropdown
    enum MenuItem: Identifiable, Equatable {
        case systemAudio
        case device(AudioDevice)

        var id: String {
            switch self {
            case .systemAudio: return "__system_audio__"
            case .device(let device): return device.uid
            }
        }

        var name: String {
            switch self {
            case .systemAudio: return "System Audio"
            case .device(let device): return device.name
            }
        }

        var icon: NSImage? {
            switch self {
            case .systemAudio: return nil
            case .device(let device): return device.icon
            }
        }
    }

    private var menuItems: [MenuItem] {
        [.systemAudio] + devices.map { .device($0) }
    }

    /// Display text for trigger button
    private var triggerText: String {
        switch mode {
        case .single:
            return singleModeText
        case .multi:
            let count = selectedDeviceUIDs.count
            if count == 0 {
                // No multi selections - show single-mode device (what's actually playing)
                return singleModeText
            }
            return "\(count) device\(count == 1 ? "" : "s")"
        }
    }

    /// Text for single-mode display (also used as fallback for empty multi-mode)
    private var singleModeText: String {
        if isFollowingDefault {
            return "System Audio"
        } else if let device = devices.first(where: { $0.uid == selectedDeviceUID }) {
            return device.name
        }
        return "Select"
    }

    /// Icon for trigger button
    @ViewBuilder
    private var triggerIcon: some View {
        switch mode {
        case .single:
            singleModeIcon
        case .multi:
            if selectedDeviceUIDs.isEmpty {
                // No multi selections - show single-mode icon
                singleModeIcon
            } else {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13))
            }
        }
    }

    /// Icon for single-mode display (also used as fallback for empty multi-mode)
    @ViewBuilder
    private var singleModeIcon: some View {
        if isFollowingDefault {
            Image(systemName: "globe")
                .font(.system(size: 13))
        } else if let device = devices.first(where: { $0.uid == selectedDeviceUID }),
                  let icon = device.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 13))
        }
    }

    // MARK: - Body

    var body: some View {
        triggerButton
            .background(
                PopoverHost(isPresented: $isExpanded) {
                    dropdownContent
                }
            )
            .onChange(of: mode) { _, newMode in
                currentMode = newMode
            }
            .onChange(of: selectedDeviceUIDs) { _, newUIDs in
                currentSelectedUIDs = newUIDs
            }
            .onAppear {
                // Initialize local state from props
                currentMode = mode
                currentSelectedUIDs = selectedDeviceUIDs
            }
    }

    // MARK: - Trigger Button

    private var triggerButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    triggerIcon
                    Text(triggerText)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 4)
            .frame(width: triggerWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(
                    isButtonHovered ? Color.white.opacity(0.35) : Color.white.opacity(0.2),
                    lineWidth: 0.5
                )
        }
        .onHover { isButtonHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isButtonHovered)
    }

    // MARK: - Dropdown Content

    private var dropdownContent: some View {
        VStack(spacing: 0) {
            // Mode toggle header (hidden for single-mode-only contexts like Settings)
            if showModeToggle {
                ModeToggle(mode: Binding(
                    get: { currentMode },
                    set: { newMode in
                        currentMode = newMode  // Update local state immediately
                        onModeChange(newMode)  // Notify parent
                        // States are independent - no copying between modes
                    }
                ))
                .padding(.horizontal, DesignTokens.Spacing.xs + 2)
                .padding(.top, DesignTokens.Spacing.xs + 2)
                .padding(.bottom, DesignTokens.Spacing.xs)

                Divider()
                    .padding(.horizontal, 6)
            }

            // Device list
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: itemSpacing) {
                    ForEach(menuItems) { item in
                        deviceRow(for: item)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 5)
            }
            .frame(maxHeight: 220)
        }
        .frame(width: popoverWidth)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    // MARK: - Device Row

    @ViewBuilder
    private func deviceRow(for item: MenuItem) -> some View {
        let isSystemAudio = item.id == "__system_audio__"
        let isDisabled = currentMode == .multi && isSystemAudio
        let isSelected = isItemSelected(item)

        DevicePickerRow(
            item: item,
            isSelected: isSelected,
            isDisabled: isDisabled,
            isMultiMode: currentMode == .multi,
            isDefaultDevice: {
                if case .device(let device) = item {
                    return device.uid == defaultDeviceUID
                }
                return false
            }(),
            onTap: {
                handleItemTap(item)
            }
        )
    }

    private func isItemSelected(_ item: MenuItem) -> Bool {
        switch currentMode {
        case .single:
            if case .systemAudio = item {
                return isFollowingDefault
            } else if case .device(let device) = item {
                return !isFollowingDefault && device.uid == selectedDeviceUID
            }
            return false
        case .multi:
            if case .device(let device) = item {
                return currentSelectedUIDs.contains(device.uid)
            }
            return false  // System Audio not selectable in multi mode
        }
    }

    private func handleItemTap(_ item: MenuItem) {
        switch currentMode {
        case .single:
            switch item {
            case .systemAudio:
                onSelectFollowDefault()
            case .device(let device):
                onDeviceSelected(device.uid)
            }
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded = false
            }

        case .multi:
            guard case .device(let device) = item else { return }
            var newSelection = currentSelectedUIDs
            if newSelection.contains(device.uid) {
                newSelection.remove(device.uid)
            } else {
                newSelection.insert(device.uid)
            }
            currentSelectedUIDs = newSelection  // Update local state immediately
            onDevicesSelected(newSelection)  // Notify parent
            // Stay open in multi mode
        }
    }
}

// MARK: - Device Picker Row

private struct DevicePickerRow: View {
    let item: DevicePicker.MenuItem
    let isSelected: Bool
    let isDisabled: Bool
    let isMultiMode: Bool
    let isDefaultDevice: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                // Selection indicator
                selectionIndicator

                // Icon
                itemIcon

                // Text content
                itemText

                Spacer()

                // Default device star
                if isDefaultDevice {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            .font(.system(size: 11))
            .foregroundColor(isDisabled ? DesignTokens.Colors.textQuaternary : .primary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered && !isDisabled ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .whenHovered { isHovered = $0 }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isMultiMode {
            // Checkbox for multi mode
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
                .frame(width: 16)
        } else {
            // Checkmark for single mode (only show when selected)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                    .frame(width: 16)
            } else {
                Spacer()
                    .frame(width: 16)
            }
        }
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item {
        case .systemAudio:
            Image(systemName: "globe")
                .font(.system(size: 13))
                .frame(width: 16)
                .foregroundStyle(isDisabled ? DesignTokens.Colors.textQuaternary : DesignTokens.Colors.textSecondary)
        case .device(let device):
            if let icon = device.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .opacity(isDisabled ? 0.4 : 1.0)
            } else {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 13))
                    .frame(width: 16)
            }
        }
    }

    @ViewBuilder
    private var itemText: some View {
        switch item {
        case .systemAudio:
            VStack(alignment: .leading, spacing: 1) {
                Text("System Audio")
                if isDisabled {
                    Text("Not available in multi mode")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textQuaternary)
                } else {
                    Text("Follows macOS default")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
        case .device(let device):
            Text(device.name)
                .lineLimit(1)
        }
    }
}

// MARK: - Convenience Initializer for Backward Compatibility

extension DevicePicker {
    /// Convenience initializer for single-mode only usage (backward compatible)
    init(
        devices: [AudioDevice],
        selectedDeviceUID: String,
        isFollowingDefault: Bool,
        defaultDeviceUID: String?,
        onDeviceSelected: @escaping (String) -> Void,
        onSelectFollowDefault: @escaping () -> Void
    ) {
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = []
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.mode = .single
        self.onModeChange = { _ in }
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = { _ in }
        self.onSelectFollowDefault = onSelectFollowDefault
        self.showModeToggle = false
    }
}

// MARK: - Previews

#Preview("Device Picker - Single Mode") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.md) {
            DevicePicker(
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[0].uid,
                isFollowingDefault: true,
                defaultDeviceUID: MockData.sampleDevices[0].uid,
                onDeviceSelected: { _ in },
                onSelectFollowDefault: {}
            )
        }
    }
}

#Preview("Device Picker - Multi Mode") {
    struct MultiModePreview: View {
        @State private var mode: DeviceSelectionMode = .multi
        @State private var selectedUIDs: Set<String> = []

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    DevicePicker(
                        devices: MockData.sampleDevices,
                        selectedDeviceUID: MockData.sampleDevices[0].uid,
                        selectedDeviceUIDs: selectedUIDs,
                        isFollowingDefault: false,
                        defaultDeviceUID: MockData.sampleDevices[0].uid,
                        mode: mode,
                        onModeChange: { mode = $0 },
                        onDeviceSelected: { _ in },
                        onDevicesSelected: { selectedUIDs = $0 },
                        onSelectFollowDefault: {},
                        showModeToggle: true
                    )

                    Text("Selected: \(selectedUIDs.count) devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return MultiModePreview()
}

#Preview("Device Picker - Interactive") {
    struct InteractivePreview: View {
        @State private var mode: DeviceSelectionMode = .single
        @State private var selectedUID: String = ""
        @State private var selectedUIDs: Set<String> = []
        @State private var isFollowingDefault = true

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    DevicePicker(
                        devices: MockData.sampleDevices,
                        selectedDeviceUID: selectedUID,
                        selectedDeviceUIDs: selectedUIDs,
                        isFollowingDefault: isFollowingDefault,
                        defaultDeviceUID: MockData.sampleDevices[0].uid,
                        mode: mode,
                        onModeChange: { newMode in
                            mode = newMode
                            if newMode == .multi {
                                isFollowingDefault = false
                            }
                        },
                        onDeviceSelected: { uid in
                            selectedUID = uid
                            isFollowingDefault = false
                        },
                        onDevicesSelected: { uids in
                            selectedUIDs = uids
                        },
                        onSelectFollowDefault: {
                            isFollowingDefault = true
                        },
                        showModeToggle: true
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode: \(mode == .single ? "Single" : "Multi")")
                        if mode == .single {
                            Text("Following default: \(isFollowingDefault ? "Yes" : "No")")
                            if !isFollowingDefault {
                                Text("Selected: \(selectedUID)")
                            }
                        } else {
                            Text("Selected: \(selectedUIDs.count) devices")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
