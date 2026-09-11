// FineTune/Views/Components/DeviceIconPicker.swift
import SwiftUI
import AppKit

/// Popover content for choosing a device's icon override. Selection applies
/// immediately via `onSelect` and the popover stays open for further browsing;
/// `onSelect(nil)` restores the automatic icon.
struct DeviceIconPicker: View {
    let device: AudioDevice
    let isInputDevice: Bool
    let currentOverride: String?
    let onSelect: (String?) -> Void

    @State private var query = ""
    @State private var driverIconPresent = false

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
        count: 6
    )

    var body: some View {
        let highlighted = highlightedSymbol

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            searchField

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    if trimmedQuery.isEmpty {
                        gridSection(title: "Suggested", symbols: suggestedSymbols, highlighted: highlighted)
                        ForEach(DeviceIconCatalog.categories) { category in
                            gridSection(title: category.name, symbols: category.entries.map(\.symbol), highlighted: highlighted)
                        }
                    } else {
                        searchResults(highlighted: highlighted)
                    }
                }
            }
            .frame(height: 300)
            .scrollIndicators(.never)

            Button("Restore Default") {
                onSelect(nil)
            }
            .controlSize(.small)
            .disabled(currentOverride == nil)
            .frame(maxWidth: .infinity)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(width: 300)
        .task(id: device.uid) {
            // Driver-vs-symbol is decided the way AudioDeviceMonitor decides it:
            // does the driver provide an icon? Probed once per device — the cache
            // stores only non-nil results, so probing per render would hit
            // CoreAudio (and disk) for every device without a driver icon.
            driverIconPresent = DeviceIconCache.shared.icon(for: device.uid) {
                device.id.readDeviceIcon()
            } != nil
        }
    }

    // MARK: - Sections

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private func searchResults(highlighted: String?) -> some View {
        let hits = DeviceIconCatalog.matching(trimmedQuery).map(\.symbol)
        if hits.isEmpty {
            Text("No matching icons")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DesignTokens.Spacing.md)
        } else {
            grid(symbols: hits, highlighted: highlighted)
        }
    }

    @ViewBuilder
    private func gridSection(title: LocalizedStringResource, symbols: [String], highlighted: String?) -> some View {
        SectionHeader(title: title)
            .frame(maxWidth: .infinity, alignment: .leading)
        grid(symbols: symbols, highlighted: highlighted)
    }

    private func grid(symbols: [String], highlighted: String?) -> some View {
        LazyVGrid(columns: Self.columns, spacing: DesignTokens.Spacing.xs) {
            ForEach(symbols, id: \.self) { symbol in
                IconCell(
                    symbol: symbol,
                    isHighlighted: symbol == highlighted,
                    onSelect: { onSelect(symbol) }
                )
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            TextField("Search icons", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(DesignTokens.Colors.recessedBackground)
        )
    }

    // MARK: - Symbol Resolution

    private var suggestedSymbols: [String] {
        Self.composeSuggested(
            leading: isInputDevice ? device.id.suggestedInputIconSymbol() : nil,
            shared: DeviceIconCatalog.suggested(
                forName: device.name,
                transport: device.id.readTransportType()
            )
        )
    }

    static func composeSuggested(leading: String?, shared: [String]) -> [String] {
        var result: [String] = leading.map { [$0] } ?? []
        for symbol in shared where !result.contains(symbol) {
            result.append(symbol)
        }
        return result
    }

    private var highlightedSymbol: String? {
        Self.highlightSymbol(
            currentOverride: currentOverride,
            automaticIsSymbol: !driverIconPresent,
            automaticSymbol: isInputDevice
                ? device.id.suggestedInputIconSymbol()
                : device.id.suggestedIconSymbol()
        )
    }

    /// Nil when the automatic icon is a driver-provided image — no grid cell is current then.
    static func highlightSymbol(
        currentOverride: String?,
        automaticIsSymbol: Bool,
        automaticSymbol: String
    ) -> String? {
        if let currentOverride { return currentOverride }
        return automaticIsSymbol ? automaticSymbol : nil
    }
}

// MARK: - Icon Cell

/// Per-cell hover state (not a shared hovered-symbol on the picker) because the
/// Suggested section repeats catalog symbols — identity by symbol would light
/// up both twins at once.
private struct IconCell: View {
    let symbol: String
    let isHighlighted: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            isHighlighted ? DesignTokens.Colors.accentPrimary : Color.clear,
                            lineWidth: 1.5
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .help(symbol)
        .accessibilityLabel(DeviceIconCatalog.entry(for: symbol)?.keywords.first?.capitalized ?? symbol)
    }

    private var fill: Color {
        if isHighlighted { return DesignTokens.Colors.glassFillStrong }
        if isHovered { return DesignTokens.Colors.hoverSurface }
        return .clear
    }
}

// MARK: - Previews

#Preview("DeviceIconPicker") {
    ComponentPreviewContainer {
        DeviceIconPicker(
            device: MockData.sampleDevices[1],
            isInputDevice: false,
            currentOverride: "gamecontroller.fill",
            onSelect: { _ in }
        )
    }
}
