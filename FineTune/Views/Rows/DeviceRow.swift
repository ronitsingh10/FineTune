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
    let currentSampleRate: Double
    let availableSampleRates: [Double]
    let canSetSampleRate: Bool
    let canDisconnectBluetooth: Bool
    let eqSettings: EQSettings
    let isEQExpanded: Bool
    let canUseEQ: Bool
    let eqDisabledReason: String?
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onSampleRateChange: (Double) -> Void
    let onDisconnectBluetooth: () -> Void
    let onEQToggle: () -> Void
    let onEQChange: (EQSettings) -> Void

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var localEQSettings: EQSettings

    /// Show muted icon when system muted OR volume is 0
    private var showMutedIcon: Bool { isMuted || sliderValue == 0 }

    /// Default volume to restore when unmuting from 0 (50%)
    private let defaultUnmuteVolume: Double = 0.5

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        isMuted: Bool,
        hasVolumeControl: Bool = true,
        currentSampleRate: Double,
        availableSampleRates: [Double] = [],
        canSetSampleRate: Bool = false,
        canDisconnectBluetooth: Bool = false,
        eqSettings: EQSettings = .flat,
        isEQExpanded: Bool = false,
        canUseEQ: Bool = true,
        eqDisabledReason: String? = nil,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        onSampleRateChange: @escaping (Double) -> Void,
        onDisconnectBluetooth: @escaping () -> Void = {},
        onEQToggle: @escaping () -> Void = {},
        onEQChange: @escaping (EQSettings) -> Void = { _ in }
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.hasVolumeControl = hasVolumeControl
        self.currentSampleRate = currentSampleRate
        self.availableSampleRates = availableSampleRates
        self.canSetSampleRate = canSetSampleRate
        self.canDisconnectBluetooth = canDisconnectBluetooth
        self.eqSettings = eqSettings
        self.isEQExpanded = isEQExpanded
        self.canUseEQ = canUseEQ
        self.eqDisabledReason = eqDisabledReason
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.onSampleRateChange = onSampleRateChange
        self.onDisconnectBluetooth = onDisconnectBluetooth
        self.onEQToggle = onEQToggle
        self.onEQChange = onEQChange
        self._sliderValue = State(initialValue: Double(volume))
        self._localEQSettings = State(initialValue: eqSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded && canUseEQ) {
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
                    // Mute button
                    MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                        if showMutedIcon {
                            // Unmute: restore to default if at 0
                            if sliderValue == 0 {
                                sliderValue = defaultUnmuteVolume
                            }
                            if isMuted {
                                onMuteToggle()  // Toggle system mute
                            }
                        } else {
                            // Mute
                            onMuteToggle()  // Toggle system mute
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

                Button {
                    guard canUseEQ else { return }
                    onEQToggle()
                } label: {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            canUseEQ
                                ? (isEQExpanded ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                                : DesignTokens.Colors.textTertiary
                        )
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(canUseEQ ? "Graphic EQ" : (eqDisabledReason ?? "Graphic EQ unavailable for this output configuration"))

                SampleRatePicker(
                    currentRate: currentSampleRate,
                    availableRates: availableSampleRates,
                    canSetRate: canSetSampleRate,
                    canDisconnect: canDisconnectBluetooth,
                    onSelect: onSampleRateChange,
                    onDisconnect: onDisconnectBluetooth
                )
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            EQPanelView(
                settings: $localEQSettings,
                onPresetSelected: { preset in
                    var updated = preset.settings
                    updated.isEnabled = localEQSettings.isEnabled
                    localEQSettings = updated
                    onEQChange(localEQSettings)
                },
                onSettingsChanged: { updated in
                    localEQSettings = updated
                    onEQChange(updated)
                },
                isUsingDeviceEQ: true,
                onUseDeviceEQ: nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            sliderValue = Double(newValue)
        }
        .onChange(of: eqSettings) { _, newValue in
            localEQSettings = newValue
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
                currentSampleRate: 48000,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {},
                onSampleRateChange: { _ in }
            )

            DeviceRow(
                device: MockData.sampleDevices[1],
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                currentSampleRate: 48000,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {},
                onSampleRateChange: { _ in }
            )

            DeviceRow(
                device: MockData.sampleDevices[2],
                isDefault: false,
                volume: 0.5,
                isMuted: true,
                currentSampleRate: 44100,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {},
                onSampleRateChange: { _ in }
            )
        }
    }
}
