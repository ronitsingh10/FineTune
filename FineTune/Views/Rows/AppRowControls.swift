// FineTune/Views/Rows/AppRowControls.swift
import SwiftUI

/// Shared controls for app rows: mute button, volume slider, percentage, VU meter, device picker.
/// Used by both AppRow (active apps) and InactiveAppRow (pinned inactive apps).
struct AppRowControls: View {
    let volume: Float
    let isMuted: Bool
    let audioLevel: Float
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let maxVolumeBoost: Float
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void

    @State private var dragOverrideValue: Double?
    private let unityNotchValue: Double = 0.5
    private let unitySnapThreshold: Double = 0.025
    private let volumeEpsilon: Float = 0.0005
    private var shouldShowUnityNotch: Bool { maxVolumeBoost > 1.0 }

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.gainToSlider(volume, maxBoost: maxVolumeBoost)
    }

    private var showMutedIcon: Bool { isMuted || sliderValue == 0 }

    private func snappedToUnityIfNeeded(_ value: Double) -> Double {
        guard shouldShowUnityNotch else { return value }
        return abs(value - unityNotchValue) <= unitySnapThreshold ? unityNotchValue : value
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                // Mute button
                MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                    if showMutedIcon {
                        if volume == 0 {
                            onVolumeChange(1.0)
                        }
                        onMuteChange(false)
                    } else {
                        onMuteChange(true)
                    }
                }

                // Volume slider
                LiquidGlassSlider(
                    value: Binding(
                        get: { sliderValue },
                        set: { newValue in
                            let snappedValue = snappedToUnityIfNeeded(newValue)
                            dragOverrideValue = snappedValue
                            let gain = VolumeMapping.sliderToGain(snappedValue, maxBoost: maxVolumeBoost)
                            if abs(gain - volume) > volumeEpsilon {
                                onVolumeChange(gain)
                            }
                            if isMuted {
                                onMuteChange(false)
                            }
                        }
                    ),
                    showUnityMarker: shouldShowUnityNotch,
                    onEditingChanged: { editing in
                        if !editing {
                            dragOverrideValue = nil
                        }
                    }
                )
                .frame(width: DesignTokens.Dimensions.sliderWidth)
                .opacity(showMutedIcon ? 0.5 : 1.0)

                // Editable volume percentage
                EditablePercentage(
                    percentage: Binding(
                        get: {
                            let gain = VolumeMapping.sliderToGain(sliderValue, maxBoost: maxVolumeBoost)
                            return Int(round(gain * 100))
                        },
                        set: { newPercentage in
                            let gain = Float(newPercentage) / 100.0
                            if abs(gain - volume) > volumeEpsilon {
                                onVolumeChange(gain)
                            }
                        }
                    ),
                    range: 0...Int(round(maxVolumeBoost * 100))
                )
            }

            // VU Meter
            VUMeter(level: audioLevel, isMuted: showMutedIcon)

            // Device picker
            DevicePicker(
                devices: devices,
                selectedDeviceUID: selectedDeviceUID,
                selectedDeviceUIDs: selectedDeviceUIDs,
                isFollowingDefault: isFollowingDefault,
                defaultDeviceUID: defaultDeviceUID,
                mode: deviceSelectionMode,
                onModeChange: onDeviceModeChange,
                onDeviceSelected: onDeviceSelected,
                onDevicesSelected: onDevicesSelected,
                onSelectFollowDefault: onSelectFollowDefault,
                showModeToggle: true
            )
            .padding(.leading, 6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
