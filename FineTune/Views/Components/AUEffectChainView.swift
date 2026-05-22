// FineTune/Views/Components/AUEffectChainView.swift
import SwiftUI

struct AUEffectChainView: View {
    let entries: [AUEffectChainEntry]
    let isBypassed: Bool
    let scanner: AUPluginScanner
    let getFavoriteIDs: () -> Set<String>
    let getCrashHistory: () -> Set<String>
    let onToggle: (UUID, Bool) -> Void
    let onRemove: (UUID) -> Void
    let onAddEffect: (AUPluginDescriptor) -> Void
    let onBypassToggle: () -> Void
    let onToggleFavorite: (String) -> Void
    let onOpenUI: (UUID) -> Void
    var onOpenGenericUI: ((UUID) -> Void)? = nil
    var failedEntryIDs: Set<UUID> = []
    var getFactoryPresets: ((UUID) -> [(index: Int, name: String)])? = nil
    var onSelectFactoryPreset: ((UUID, Int) -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            if !entries.isEmpty {
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { !isBypassed },
                        set: { _ in onBypassToggle() }
                    ))
                    .toggleStyle(.switch)
                    .scaleEffect(0.7)
                    .labelsHidden()

                    Text("Effects")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(.primary)

                    Spacer()

                    if isBypassed {
                        Text("Bypassed")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                }
            }

            ForEach(entries) { entry in
                effectRow(entry)
                    .opacity(isBypassed ? 0.5 : 1.0)
            }

            AUPluginPickerMenu(
                scanner: scanner,
                getFavoriteIDs: getFavoriteIDs,
                getCrashHistory: getCrashHistory,
                onPluginSelected: onAddEffect,
                onToggleFavorite: onToggleFavorite
            )
        }
        .padding(.top, entries.isEmpty ? 0 : DesignTokens.Spacing.sm)
    }

    // MARK: - Effect Row

    private func effectRow(_ entry: AUEffectChainEntry) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { onToggle(entry.id, $0) }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.6)
            .labelsHidden()

            Button {
                onOpenUI(entry.id)
            } label: {
                HStack(spacing: 3) {
                    Text(entry.pluginDescriptor.name)
                        .font(.system(size: 11))
                        .foregroundStyle(entry.isEnabled ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                    if failedEntryIDs.contains(entry.id) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .help("Failed to load — plugin may be missing or incompatible")
                    }
                }
                .help(failedEntryIDs.contains(entry.id) ? "Plugin failed to load" : "Click to open Audio Unit interface")
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open Custom Interface") { onOpenUI(entry.id) }
                if let onGeneric = onOpenGenericUI {
                    Button("Open Generic Interface") { onGeneric(entry.id) }
                }
            }

            Spacer()

            // Factory preset picker
            if let getPresets = getFactoryPresets,
               let onSelect = onSelectFactoryPreset {
                let presets = getPresets(entry.id)
                if !presets.isEmpty {
                    Menu {
                        Button {
                            onSelect(entry.id, -1)
                        } label: {
                            if entry.selectedFactoryPresetIndex == nil {
                                Label("Default", systemImage: "checkmark")
                            } else {
                                Text("Default")
                            }
                        }
                        Divider()
                        ForEach(presets, id: \.index) { preset in
                            Button {
                                onSelect(entry.id, preset.index)
                            } label: {
                                if entry.selectedFactoryPresetIndex == preset.index {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    } label: {
                        Text(factoryPresetLabel(entry: entry, presets: presets))
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            Button {
                onRemove(entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove effect")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(DesignTokens.Colors.recessedBackground)
        )
    }

    private func factoryPresetLabel(entry: AUEffectChainEntry, presets: [(index: Int, name: String)]) -> String {
        if let idx = entry.selectedFactoryPresetIndex,
           let match = presets.first(where: { $0.index == idx }) {
            return match.name
        }
        return "Preset"
    }
}
