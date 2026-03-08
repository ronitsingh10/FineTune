// FineTune/Views/Rows/PairedDeviceRow.swift
import SwiftUI

/// A row for a paired-but-disconnected Bluetooth device.
/// Shows device icon, name, and a Connect button or spinner while connecting.
struct PairedDeviceRow: View {
    let device: PairedBluetoothDevice
    let isConnecting: Bool
    let errorMessage: String?
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Spacer matching RadioButton width for alignment with DeviceRow
            Color.clear
                .frame(
                    width: DesignTokens.Dimensions.minTouchTarget,
                    height: DesignTokens.Dimensions.minTouchTarget
                )

            // Device icon
            Group {
                if let icon = device.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "headphones")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
            .opacity(isConnecting ? 0.5 : 1.0)

            // Device name
            Text(device.name)
                .font(DesignTokens.Typography.rowName)
                .foregroundStyle(isConnecting
                    ? DesignTokens.Colors.textSecondary
                    : DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Inline error (between name and button)
            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }

            // Connect button or spinner
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        minWidth: DesignTokens.Dimensions.minTouchTarget,
                        minHeight: DesignTokens.Dimensions.minTouchTarget
                    )
            } else {
                Button("Connect") {
                    onConnect()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accentPrimary)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                        .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                        .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.3), lineWidth: 0.5)
                )
            }
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .hoverableRow()
    }
}

// MARK: - Previews

#Preview("Paired Device Row") {
    PreviewContainer {
        VStack(spacing: DesignTokens.Spacing.xs) {
            PairedDeviceRow(
                device: MockData.samplePairedDevices[0],
                isConnecting: false,
                errorMessage: nil,
                onConnect: {}
            )
            PairedDeviceRow(
                device: MockData.samplePairedDevices[1],
                isConnecting: true,
                errorMessage: nil,
                onConnect: {}
            )
            PairedDeviceRow(
                device: MockData.samplePairedDevices[0],
                isConnecting: false,
                errorMessage: "Connection timed out",
                onConnect: {}
            )
        }
    }
}
