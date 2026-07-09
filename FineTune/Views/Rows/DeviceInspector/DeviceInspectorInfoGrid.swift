// FineTune/Views/Rows/DeviceInspector/DeviceInspectorInfoGrid.swift
import AppKit
import SwiftUI

/// Column-aligned info grid for the Device Inspector pane.
@MainActor
struct DeviceInspectorInfoGrid: View {
    let info: DeviceInspectorInfo
    let onSampleRateSelected: (Double) -> Void

    var body: some View {
        let layout = InfoGridLayout(info: info)
        Grid(
            alignment: .leadingFirstTextBaseline,
            horizontalSpacing: DesignTokens.Spacing.md,
            verticalSpacing: 4
        ) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                rowView(for: row)
            }
        }
    }

    @ViewBuilder
    private func rowView(for row: InfoGridLayout.Row) -> some View {
        switch row {
        case .transport(let value):
            GridRow {
                labelCell("Transport")
                valueCell(value)
            }
        case .sampleRate(let display, let isPicker, let options):
            GridRow {
                labelCell("Sample rate")
                if isPicker {
                    SampleRatePickerValue(
                        currentDisplay: display,
                        options: options,
                        onSelect: onSampleRateSelected
                    )
                    .gridColumnAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    valueCell(display)
                }
            }
        case .format(let value):
            GridRow {
                labelCell("Format")
                valueCell(value)
            }
        case .deviceID(let uid):
            GridRow {
                labelCell("Device ID")
                DeviceIDValueCell(uid: uid)
                    .gridColumnAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func labelCell(_ text: String) -> some View {
        Text(L10n.string(text))
            .font(DesignTokens.Typography.pickerText)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func valueCell(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.pickerText)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .lineLimit(1)
            .gridColumnAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Sample-rate picker (glass button with chevron on the right)

private struct SampleRatePickerValue: View {
    let currentDisplay: String
    let options: [Double]
    let onSelect: (Double) -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { rate in
                Button(DeviceInspectorInfo.formatSampleRate(rate)) {
                    onSelect(rate)
                }
            }
        } label: {
            pickerLabel
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .background(pickerBackground)
        .overlay(pickerBorder)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(L10n.format("Sample rate: %@. Activate to change.", currentDisplay))
    }

    private var pickerLabel: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(currentDisplay)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var pickerBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
            .fill(.regularMaterial)
    }

    private var pickerBorder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
            .strokeBorder(
                isHovered ? DesignTokens.Colors.glassRowBorderHover : DesignTokens.Colors.glassRowBorder,
                lineWidth: 0.5
            )
    }
}

// MARK: - Device ID value cell with inline copy button

private struct DeviceIDValueCell: View {
    let uid: String

    @State private var copied = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(uid)
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(uid)

            Button(action: copyToClipboard) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(
                        copied
                            ? DesignTokens.Colors.accentPrimary
                            : DesignTokens.Colors.textTertiary
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(copied ? "Copied" : "Copy device ID"))
            .accessibilityLabel(L10n.string(copied ? "Device ID copied" : "Copy device ID"))
        }
        .accessibilityElement(children: .contain)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uid, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
