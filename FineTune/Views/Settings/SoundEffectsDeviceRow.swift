// FineTune/Views/Settings/SoundEffectsDeviceRow.swift
import SwiftUI

/// Settings row for selecting the sound effects output device
struct SoundEffectsDeviceRow: View {
    let devices: [AudioDevice]
    let unconnectedBluetoothSources: [BluetoothAudioSource]
    let selectedDeviceUID: String?
    let defaultDeviceUID: String?
    let isFollowingDefault: Bool
    let onDeviceSelected: (String) -> Void
    let onSelectFollowDefault: () -> Void
    let onConnectBluetoothSource: (BluetoothAudioSource) -> Void

    var body: some View {
        SettingsRowView(
            icon: "bell.fill",
            title: "Sound Effects",
            description: "Output device for alerts, notifications, and Siri"
        ) {
            DevicePicker(
                devices: devices,
                selectedDeviceUID: selectedDeviceUID ?? "",
                isFollowingDefault: isFollowingDefault,
                defaultDeviceUID: defaultDeviceUID,
                unconnectedBluetoothSources: unconnectedBluetoothSources,
                onConnectBluetoothSource: onConnectBluetoothSource,
                onDeviceSelected: { onDeviceSelected($0) },
                onSelectFollowDefault: { onSelectFollowDefault() }
            )
        }
    }
}

// MARK: - Previews

#Preview("Sound Effects Device Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SoundEffectsDeviceRow(
            devices: MockData.sampleDevices,
            unconnectedBluetoothSources: [],
            selectedDeviceUID: MockData.sampleDevices[0].uid,
            defaultDeviceUID: MockData.sampleDevices[0].uid,
            isFollowingDefault: true,
            onDeviceSelected: { _ in },
            onSelectFollowDefault: {},
            onConnectBluetoothSource: { _ in }
        )
    }
    .padding()
    .frame(width: 500)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
