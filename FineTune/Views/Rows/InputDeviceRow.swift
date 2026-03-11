// FineTune/Views/Rows/InputDeviceRow.swift
import SwiftUI

/// A row displaying an input device (microphone) with volume controls
/// Used in the Input Devices section
struct InputDeviceRow: View {
    let device: AudioDevice
    let isDefault: Bool
    let volume: Float
    let isMuted: Bool
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void

    @State private var sliderValue: Double
    @State private var isEditing = false

    /// Show muted icon when system muted OR volume is 0
    private var showMutedIcon: Bool { isMuted || sliderValue == 0 }

    /// Default volume to restore when unmuting from 0 (50%)
    private let defaultUnmuteVolume: Double = 0.5

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        isMuted: Bool,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self._sliderValue = State(initialValue: Double(volume))
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Default device selector
            RadioButton(isSelected: isDefault, action: onSetDefault)

            // Device icon - use mic as fallback for input devices
            Group {
                if let icon = device.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "mic")
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

            // Mute button (mic icon)
            InputMuteButton(isMuted: showMutedIcon) {
                if showMutedIcon {
                    // Unmute: restore to default if at 0
                    if sliderValue == 0 {
                        sliderValue = defaultUnmuteVolume
                    }
                    if isMuted {
                        onMuteToggle()
                    }
                } else {
                    // Mute
                    onMuteToggle()
                }
            }

            // Volume slider (Liquid Glass)
            LiquidGlassSlider(
                value: $sliderValue,
                onEditingChanged: { editing in
                    isEditing = editing
                }
            )
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .onChange(of: sliderValue) { _, newValue in
                onVolumeChange(Float(newValue))
                // Auto-unmute when slider moved while muted
                if isMuted && newValue > 0 {
                    onMuteToggle()
                }
            }

            // Editable volume percentage
            EditablePercentage(
                percentage: Binding(
                    get: { Int(round(sliderValue * 100)) },
                    set: { sliderValue = Double($0) / 100.0 }
                ),
                range: 0...100
            )
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .hoverableRow()
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            sliderValue = Double(newValue)
        }
    }
}

// MARK: - Previews

#Preview("Input Device Row - Default") {
    PreviewContainer {
        VStack(spacing: 0) {
            InputDeviceRow(
                device: AudioDevice(
                    id: 1,
                    uid: "built-in-mic",
                    name: "MacBook Pro Microphone",
                    icon: nil
                ),
                isDefault: true,
                volume: 0.75,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            InputDeviceRow(
                device: AudioDevice(
                    id: 2,
                    uid: "usb-mic",
                    name: "Blue Yeti",
                    icon: nil
                ),
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            InputDeviceRow(
                device: AudioDevice(
                    id: 3,
                    uid: "airpods-mic",
                    name: "AirPods Pro",
                    icon: nil
                ),
                isDefault: false,
                volume: 0.5,
                isMuted: true,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )
        }
    }
}
