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
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void

    // AutoEQ (all optional — existing call sites work without them)
    let autoEQProfileName: String?
    let autoEQEnabled: Bool
    let onAutoEQToggle: (() -> Void)?
    let autoEQProfileManager: AutoEQProfileManager?
    let autoEQSelection: AutoEQSelection?
    let autoEQFavoriteIDs: Set<String>
    let onAutoEQSelect: ((AutoEQProfile?) -> Void)?
    let onAutoEQImport: (() -> Void)?
    let onAutoEQToggleFavorite: ((String) -> Void)?
    let autoEQImportError: String?

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
        hasVolumeControl: Bool = true,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        autoEQProfileName: String? = nil,
        autoEQEnabled: Bool = false,
        onAutoEQToggle: (() -> Void)? = nil,
        autoEQProfileManager: AutoEQProfileManager? = nil,
        autoEQSelection: AutoEQSelection? = nil,
        autoEQFavoriteIDs: Set<String> = [],
        onAutoEQSelect: ((AutoEQProfile?) -> Void)? = nil,
        onAutoEQImport: (() -> Void)? = nil,
        onAutoEQToggleFavorite: ((String) -> Void)? = nil,
        autoEQImportError: String? = nil
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.hasVolumeControl = hasVolumeControl
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.autoEQProfileName = autoEQProfileName
        self.autoEQEnabled = autoEQEnabled
        self.onAutoEQToggle = onAutoEQToggle
        self.autoEQProfileManager = autoEQProfileManager
        self.autoEQSelection = autoEQSelection
        self.autoEQFavoriteIDs = autoEQFavoriteIDs
        self.onAutoEQSelect = onAutoEQSelect
        self.onAutoEQImport = onAutoEQImport
        self.onAutoEQToggleFavorite = onAutoEQToggleFavorite
        self.autoEQImportError = autoEQImportError
        self._sliderValue = State(initialValue: Double(volume))
    }

    var body: some View {
        deviceHeader
            .hoverableRow()
    }

    // MARK: - Device Header

    private var deviceHeader: some View {
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

            // Device name + optional AutoEQ profile subtitle + AutoEQ picker
            HStack(spacing: DesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(isDefault ? DesignTokens.Typography.rowNameBold : DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .help(device.name)

                    if let profileName = autoEQProfileName, autoEQEnabled {
                        Text(profileName)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // AutoEQ picker inside the name area so slider length stays consistent
                if device.supportsAutoEQ,
                   let profileManager = autoEQProfileManager,
                   let onSelect = onAutoEQSelect,
                   let onImport = onAutoEQImport {
                    AutoEQPicker(
                        profileManager: profileManager,
                        profileName: autoEQProfileName,
                        selection: autoEQSelection,
                        favoriteIDs: autoEQFavoriteIDs,
                        onSelect: onSelect,
                        onImport: onImport,
                        onToggleFavorite: { id in onAutoEQToggleFavorite?(id) },
                        importError: autoEQImportError
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasVolumeControl {
                // Mute button
                MuteButton(isMuted: showMutedIcon) {
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
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            sliderValue = Double(newValue)
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

            DeviceRow(
                device: MockData.sampleDevices[2],
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
