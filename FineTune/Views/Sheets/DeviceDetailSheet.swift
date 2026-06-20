// FineTune/Views/Sheets/DeviceDetailSheet.swift
import SwiftUI
import os

@MainActor
struct DeviceDetailSheet: View {
    let device: AudioDevice
    let transportType: TransportType
    let autoDetectedTier: VolumeControlTier
    let currentOverride: VolumeControlTier?
    let onOverrideChange: (VolumeControlTier?) -> Void
    let isLoudnessCompensationEnabled: Bool
    let onLoudnessCompensationToggle: (Bool) -> Void
    let loudnessReferencePhon: Double
    let onLoudnessReferencePhonChange: (Double) -> Void
    let onDismiss: () -> Void

    @State private var viewModel: DeviceInspectorViewModel
    @State private var showAdvanced: Bool = false

    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "DeviceDetailSheet")

    init(
        device: AudioDevice,
        transportType: TransportType,
        autoDetectedTier: VolumeControlTier,
        currentOverride: VolumeControlTier?,
        onOverrideChange: @escaping (VolumeControlTier?) -> Void,
        isLoudnessCompensationEnabled: Bool,
        onLoudnessCompensationToggle: @escaping (Bool) -> Void,
        loudnessReferencePhon: Double,
        onLoudnessReferencePhonChange: @escaping (Double) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.device = device
        self.transportType = transportType
        self.autoDetectedTier = autoDetectedTier
        self.currentOverride = currentOverride
        self.onOverrideChange = onOverrideChange
        self.isLoudnessCompensationEnabled = isLoudnessCompensationEnabled
        self.onLoudnessCompensationToggle = onLoudnessCompensationToggle
        self.loudnessReferencePhon = loudnessReferencePhon
        self.onLoudnessReferencePhonChange = onLoudnessReferencePhonChange
        self.onDismiss = onDismiss
        self._viewModel = State(
            initialValue: DeviceInspectorViewModel(
                deviceID: device.id,
                uid: device.uid,
                transportType: transportType
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            DeviceInspectorInfoGrid(
                info: viewModel.info,
                onSampleRateSelected: { rate in
                    viewModel.selectSampleRate(rate)
                }
            )

            if let error = viewModel.sampleRateError {
                errorBanner(error)
            }

            if let hogLine = DeviceInspectorInfo.formatHogModeOwner(
                viewModel.info.hogModeOwner,
                processName: viewModel.hogModeOwnerName
            ) {
                separator
                hogModeRow(hogLine)
            }

            if Self.shouldShowToggle(autoTier: autoDetectedTier) {
                separator
                softwareToggle
                calloutText
            }

            separator
            loudnessCompensationToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Auto badge

    private var autoBadge: some View {
        Text("Auto: \(Self.tierDisplayName(autoDetectedTier))")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignTokens.Colors.glassFillStrong)
            )
            .accessibilityLabel("Auto-detected volume control: \(Self.tierDisplayName(autoDetectedTier))")
    }

    // MARK: - Separator

    private var separator: some View {
        Rectangle()
            .fill(DesignTokens.Colors.separator)
            .frame(height: 0.5)
    }

    // MARK: - Hog mode row

    private func hogModeRow(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Error banner

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.mutedIndicator)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Software Toggle

    @ViewBuilder
    private var softwareToggle: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            autoBadge

            Text("Use FineTune's software volume")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle("", isOn: useSoftwareBinding)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
    }

    /// OFF writes `nil` (clears the pin, re-runs auto-detect); ON pins `.software`.
    private var useSoftwareBinding: Binding<Bool> {
        Binding(
            get: { currentOverride == .some(.software) },
            set: { newValue in
                Self.logger.debug("Toggle flipped: uid=\(device.uid, privacy: .public) useSoftware=\(newValue, privacy: .public)")
                onOverrideChange(newValue ? .some(.software) : nil)
            }
        )
    }

    // MARK: - Callout

    private var calloutText: some View {
        Text("Turn on only if the volume slider doesn't work. FineTune remembers this for each device.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }



    // MARK: - Loudness Compensation Toggle

    @ViewBuilder
    private var loudnessCompensationToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Loudness Compensation")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Spacer(minLength: DesignTokens.Spacing.sm)

                Toggle("", isOn: Binding(
                    get: { isLoudnessCompensationEnabled },
                    set: { onLoudnessCompensationToggle($0) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
            }
            Text("Boost low frequencies at low volumes for this device.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoudnessCompensationEnabled {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAdvanced.toggle()
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Text("Device Reference Level")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            
                            Spacer()
                            
                            Text(Self.referenceLevelDisplayName(phon: loudnessReferencePhon, isExpanded: showAdvanced))
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    if showAdvanced {
                        VStack(alignment: .leading, spacing: 6) {
                            Slider(
                                value: Binding(
                                    get: { loudnessReferencePhon },
                                    set: { onLoudnessReferencePhonChange($0) }
                                ),
                                in: 20...120,
                                step: 1
                            )
                            .controlSize(.mini)
                            
                            Text("Fine-tunes loudness compensation for unusual speakers or headphones. Most users should leave this at Default.")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            HStack {
                                Spacer()
                                Button {
                                    onLoudnessReferencePhonChange(ISO226Contours.defaultReferencePhon)
                                } label: {
                                    Text("Reset to Default")
                                        .font(DesignTokens.Typography.caption)
                                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(loudnessReferencePhon == ISO226Contours.defaultReferencePhon)
                            }
                        }
                        .padding(.leading, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    static func referenceLevelDisplayName(phon: Double, isExpanded: Bool) -> String {
        if isExpanded {
            return "\(Int(phon)) phon"
        } else {
            return phon == ISO226Contours.defaultReferencePhon ? "Default" : "Custom"
        }
    }

    static func tierDisplayName(_ tier: VolumeControlTier) -> String {
        switch tier {
        case .hardware: return "Hardware"
        case .ddc: return "DDC"
        case .software: return "Software"
        }
    }

    /// Hidden when auto-tier is already `.software` — no alternative backend to switch to.
    static func shouldShowToggle(autoTier: VolumeControlTier) -> Bool {
        autoTier != .software
    }
}
