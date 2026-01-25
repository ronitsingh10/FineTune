// FineTune/Views/Components/DevicePicker.swift
import SwiftUI

/// Selection state for device picker - either following system default or explicit device
enum DeviceSelection: Equatable {
    case systemAudio
    case device(String)  // deviceUID
}

/// A styled device picker dropdown with "System Audio" option
struct DevicePicker: View {
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let onDeviceSelected: (String) -> Void
    let onSelectFollowDefault: () -> Void

    /// Menu item representation for unified dropdown
    private enum MenuItem: Identifiable, Equatable {
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

    private var selectedItem: MenuItem {
        if isFollowingDefault {
            return .systemAudio
        } else {
            if let device = devices.first(where: { $0.uid == selectedDeviceUID }) {
                return .device(device)
            }
            return .systemAudio
        }
    }

    var body: some View {
        DropdownMenu(
            items: menuItems,
            selectedItem: selectedItem,
            maxVisibleItems: 8,
            width: 128,
            popoverWidth: 200,
            onSelect: { item in
                switch item {
                case .systemAudio:
                    onSelectFollowDefault()
                case .device(let device):
                    onDeviceSelected(device.uid)
                }
            }
        ) { selected in
            // Trigger content
            HStack(spacing: DesignTokens.Spacing.xs) {
                if case .systemAudio = selected {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                } else if let icon = selected?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 14))
                }
                Text(selected?.name ?? "Select")
                    .lineLimit(1)
            }
        } itemContent: { item, isSelected in
            // Menu item content
            HStack {
                switch item {
                case .systemAudio:
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Audio")
                        Text("Follows macOS default")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                case .device(let device):
                    if let icon = device.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 14))
                            .frame(width: 16)
                    }
                    Text(device.name)
                    // Show star for current macOS default device
                    if device.uid == defaultDeviceUID {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Device Picker - Following Default") {
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

#Preview("Device Picker - Explicit Device") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.md) {
            DevicePicker(
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[1].uid,
                isFollowingDefault: false,
                defaultDeviceUID: MockData.sampleDevices[0].uid,
                onDeviceSelected: { _ in },
                onSelectFollowDefault: {}
            )
        }
    }
}
