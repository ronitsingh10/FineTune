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
    let onDismiss: () -> Void

    @State private var viewModel: DeviceInspectorViewModel

    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "DeviceDetailSheet")

    init(
        device: AudioDevice,
        transportType: TransportType,
        autoDetectedTier: VolumeControlTier,
        currentOverride: VolumeControlTier?,
        onOverrideChange: @escaping (VolumeControlTier?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.device = device
        self.transportType = transportType
        self.autoDetectedTier = autoDetectedTier
        self.currentOverride = currentOverride
        self.onOverrideChange = onOverrideChange
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
        Text(L10n.format("Auto: %@", Self.tierDisplayName(autoDetectedTier)))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignTokens.Colors.glassFillStrong)
            )
            .accessibilityLabel(L10n.format("Auto-detected volume control: %@", Self.tierDisplayName(autoDetectedTier)))
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

            Text(L10n.string("Use FineTune's software volume"))
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
        Text(L10n.string("Turn on only if the volume slider doesn't work. FineTune remembers this for each device."))
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    static func tierDisplayName(_ tier: VolumeControlTier) -> String {
        switch tier {
        case .hardware: return L10n.string("Hardware")
        case .ddc: return "DDC"
        case .software: return L10n.string("Software")
        }
    }

    /// Hidden when auto-tier is already `.software` — no alternative backend to switch to.
    static func shouldShowToggle(autoTier: VolumeControlTier) -> Bool {
        autoTier != .software
    }
}
