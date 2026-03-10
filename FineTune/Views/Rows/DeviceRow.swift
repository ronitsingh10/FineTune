// FineTune/Views/Rows/DeviceRow.swift
import SwiftUI

/// A row displaying a device with volume controls
/// Used in the Output Devices section
struct DeviceRow: View {
    let device: AudioDevice
    let isDefault: Bool
    let volume: Float
    let isMuted: Bool
    let hasVolumeControl: Bool
    // Software volume (for HDMI/devices without hardware volume)
    let softwareVolume: Float
    let isSoftwareMuted: Bool
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onSoftwareVolumeChange: (Float) -> Void
    let onSoftwareMuteToggle: () -> Void

    @State private var sliderValue: Double
    @State private var softwareSliderValue: Double
    @State private var isEditing = false

    /// Show muted icon when system muted OR volume is 0
    private var showMutedIcon: Bool { isMuted || sliderValue == 0 }
    /// Show software muted icon when software muted OR software volume is 0
    private var showSoftwareMutedIcon: Bool { isSoftwareMuted || softwareSliderValue == 0 }

    /// Default volume to restore when unmuting from 0 (50%)
    private let defaultUnmuteVolume: Double = 0.5

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        isMuted: Bool,
        hasVolumeControl: Bool = true,
        softwareVolume: Float = 1.0,
        isSoftwareMuted: Bool = false,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        onSoftwareVolumeChange: @escaping (Float) -> Void = { _ in },
        onSoftwareMuteToggle: @escaping () -> Void = {}
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.hasVolumeControl = hasVolumeControl
        self.softwareVolume = softwareVolume
        self.isSoftwareMuted = isSoftwareMuted
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.onSoftwareVolumeChange = onSoftwareVolumeChange
        self.onSoftwareMuteToggle = onSoftwareMuteToggle
        self._sliderValue = State(initialValue: Double(volume))
        self._softwareSliderValue = State(initialValue: Double(softwareVolume))
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Default device selector
            RadioButton(isSelected: isDefault, action: onSetDefault)

            // Device icon (vibrancy-aware)
            Group {
                if let icon = device.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "speaker.wave.2")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)

            // Device name
            Text(device.name)
                .font(isDefault ? DesignTokens.Typography.rowNameBold : DesignTokens.Typography.rowName)
                .lineLimit(1)
                .help(device.name)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasVolumeControl {
                // ── Hardware volume controls (existing path) ──────────────────
                MuteButton(isMuted: showMutedIcon) {
                    if showMutedIcon {
                        if sliderValue == 0 {
                            sliderValue = defaultUnmuteVolume
                        }
                        if isMuted {
                            onMuteToggle()
                        }
                    } else {
                        onMuteToggle()
                    }
                }

                LiquidGlassSlider(
                    value: $sliderValue,
                    onEditingChanged: { editing in
                        isEditing = editing
                    }
                )
                .opacity(showMutedIcon ? 0.5 : 1.0)
                .onChange(of: sliderValue) { _, newValue in
                    onVolumeChange(Float(newValue))
                    if isMuted && newValue > 0 {
                        onMuteToggle()
                    }
                }

                EditablePercentage(
                    percentage: Binding(
                        get: { Int(round(sliderValue * 100)) },
                        set: { sliderValue = Double($0) / 100.0 }
                    ),
                    range: 0...100
                )
            } else {
                // ── Software volume controls (HDMI / no hardware volume) ───────
                // "SW" badge signals this is a software gain stage
                Text("SW")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .strokeBorder(DesignTokens.Colors.textTertiary.opacity(0.4), lineWidth: 0.5)
                    )
                    .help("Software volume — this device has no hardware volume control")

                MuteButton(isMuted: showSoftwareMutedIcon) {
                    if showSoftwareMutedIcon {
                        if softwareSliderValue == 0 {
                            softwareSliderValue = defaultUnmuteVolume
                            onSoftwareVolumeChange(Float(defaultUnmuteVolume))
                        }
                        if isSoftwareMuted {
                            onSoftwareMuteToggle()
                        }
                    } else {
                        onSoftwareMuteToggle()
                    }
                }

                LiquidGlassSlider(
                    value: $softwareSliderValue,
                    onEditingChanged: { editing in
                        isEditing = editing
                    }
                )
                .opacity(showSoftwareMutedIcon ? 0.5 : 1.0)
                .onChange(of: softwareSliderValue) { _, newValue in
                    onSoftwareVolumeChange(Float(newValue))
                    if isSoftwareMuted && newValue > 0 {
                        onSoftwareMuteToggle()
                    }
                }

                EditablePercentage(
                    percentage: Binding(
                        get: { Int(round(softwareSliderValue * 100)) },
                        set: { softwareSliderValue = Double($0) / 100.0 }
                    ),
                    range: 0...100
                )
            }
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .hoverableRow()
        .onAppear {
            // Force-sync @State from the prop on every appearance.
            // @State only initialises from the init argument on first creation,
            // so if the row is recreated (DDC probe, device list refresh, etc.)
            // while the prop already has the correct value, .onChange never fires.
            sliderValue = Double(volume)
            softwareSliderValue = Double(softwareVolume)
        }
        .onChange(of: volume) { _, newValue in
            guard !isEditing else { return }
            sliderValue = Double(newValue)
        }
        .onChange(of: softwareVolume) { _, newValue in
            guard !isEditing else { return }
            softwareSliderValue = Double(newValue)
        }
    }
}

// MARK: - Previews

#Preview("Device Row - Default") {
    PreviewContainer {
        VStack(spacing: 0) {
            DeviceRow(
                device: MockData.sampleDevices[0],
                isDefault: true,
                volume: 0.75,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[1],
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            // Software volume row (simulating HDMI TV)
            DeviceRow(
                device: MockData.sampleDevices[2],
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                hasVolumeControl: false,
                softwareVolume: 0.7,
                isSoftwareMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {},
                onSoftwareVolumeChange: { _ in },
                onSoftwareMuteToggle: {}
            )
        }
    }
}
