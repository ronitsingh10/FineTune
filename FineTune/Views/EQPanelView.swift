// FineTune/Views/EQPanelView.swift
import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

struct EQPanelView: View {
    @Binding var settings: EQSettings
    let onPresetSelected: (EQPreset) -> Void
    let onSettingsChanged: (EQSettings) -> Void

    @Binding var headphoneSettings: HeadphoneEQSettings
    let onHeadphoneSettingsChanged: (HeadphoneEQSettings) -> Void
    let onHeadphoneProfileImport: (URL) -> Result<HeadphoneEQSettings, Error>

    let isUsingDeviceEQ: Bool
    let onUseDeviceEQ: (() -> Void)?

    @State private var headphoneImportErrorMessage: String?
    @State private var isRemoveProfileButtonHovered = false

    private let frequencyLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    private var currentPreset: EQPreset? {
        EQPreset.allCases.first { preset in
            preset.settings.bandGains == settings.bandGains
        }
    }

    private var hasHeadphoneProfile: Bool {
        headphoneSettings.hasProfile
    }

    private var headphoneProfileSummary: String {
        let name = headphoneSettings.profileName.isEmpty ? "Imported profile" : headphoneSettings.profileName
        return "\(name) • \(headphoneSettings.filters.count) filter(s)"
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 12) {
                // Header: Toggle left, Preset right
                HStack {
                    // EQ toggle on left
                    HStack(spacing: 6) {
                        Toggle("", isOn: $settings.isEnabled)
                            .toggleStyle(.switch)
                            .scaleEffect(0.7)
                            .labelsHidden()
                            .onChange(of: settings.isEnabled) { _, _ in
                                onSettingsChanged(settings)
                            }
                        Text("Graphic EQ")
                            .font(DesignTokens.Typography.pickerText)
                            .foregroundColor(.primary)
                    }
                    .offset(x: -8)

                    Spacer()

                    // Preset picker on right
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let onUseDeviceEQ {
                            Button(isUsingDeviceEQ ? "Using Device EQ" : "Use Device EQ") {
                                if !isUsingDeviceEQ {
                                    onUseDeviceEQ()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(isUsingDeviceEQ ? DesignTokens.Colors.textTertiary : DesignTokens.Colors.interactiveDefault)
                        }

                        Text("Preset")
                            .font(DesignTokens.Typography.pickerText)
                            .foregroundColor(DesignTokens.Colors.textSecondary)

                        EQPresetPicker(
                            selectedPreset: currentPreset,
                            onPresetSelected: onPresetSelected
                        )
                    }
                    .opacity(settings.isEnabled ? 1.0 : 0.45)
                    .allowsHitTesting(settings.isEnabled)
                }
                .zIndex(1)  // Ensure dropdown renders above sliders

                // 10-band sliders
                HStack(spacing: 22) {
                    ForEach(0..<10, id: \.self) { index in
                        EQSliderView(
                            frequency: frequencyLabels[index],
                            gain: Binding(
                                get: { settings.bandGains[index] },
                                set: { newValue in
                                    settings.bandGains[index] = newValue
                                    onSettingsChanged(settings)
                                }
                            )
                        )
                        .frame(width: 26, height: 100)
                    }
                }
                .opacity(settings.isEnabled ? 1.0 : 0.45)
                .allowsHitTesting(settings.isEnabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignTokens.Colors.recessedBackground)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { headphoneSettings.isEnabled },
                                set: { enabled in
                                    guard hasHeadphoneProfile else { return }
                                    headphoneSettings.isEnabled = enabled
                                    onHeadphoneSettingsChanged(headphoneSettings)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .labelsHidden()
                        .disabled(!hasHeadphoneProfile)

                        Text("Headphone EQ")
                            .font(DesignTokens.Typography.pickerText)
                            .foregroundColor(.primary)
                    }
                    .offset(x: -8)

                    Spacer()

                    if hasHeadphoneProfile {
                        HStack(spacing: 6) {
                            Text(headphoneProfileSummary)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(headphoneSettings.sourceFileName ?? headphoneProfileSummary)

                            Button {
                                clearHeadphoneProfile()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(isRemoveProfileButtonHovered ? Color.white.opacity(0.16) : Color.clear)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(
                                            isRemoveProfileButtonHovered
                                                ? DesignTokens.Colors.interactiveHover
                                                : DesignTokens.Colors.textTertiary
                                        )
                                }
                                .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .help("Remove profile")
                            .onHover { isRemoveProfileButtonHovered = $0 }
                            .animation(DesignTokens.Animation.hover, value: isRemoveProfileButtonHovered)
                        }
                    } else {
                        Button("Import Profile") {
                            importHeadphoneProfile()
                        }
                        .buttonStyle(.plain)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignTokens.Colors.recessedBackground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 0)
        .padding(.vertical, 2)
        .alert("Headphone EQ Import Failed", isPresented: Binding(
            get: { headphoneImportErrorMessage != nil },
            set: { shouldShow in
                if !shouldShow { headphoneImportErrorMessage = nil }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(headphoneImportErrorMessage ?? "Unknown error")
        }
    }

    private func importHeadphoneProfile() {
        guard let fileURL = presentAutoEQImportPanel() else { return }
        switch onHeadphoneProfileImport(fileURL) {
        case .success(let imported):
            headphoneSettings = imported
            onHeadphoneSettingsChanged(imported)
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                return
            }
            headphoneImportErrorMessage = error.localizedDescription
        }
    }

    private func clearHeadphoneProfile() {
        headphoneSettings = .empty
        onHeadphoneSettingsChanged(.empty)
    }

    private func presentAutoEQImportPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.prompt = "Import"
        panel.title = "Import AutoEQ Profile"
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
    }
}

#Preview {
    // Simulating how it appears inside ExpandableGlassRow
    VStack {
        EQPanelView(
            settings: .constant(EQSettings()),
            onPresetSelected: { _ in },
            onSettingsChanged: { _ in },
            headphoneSettings: .constant(.empty),
            onHeadphoneSettingsChanged: { _ in },
            onHeadphoneProfileImport: { _ in
                .failure(NSError(domain: "Preview", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not available in preview"]))
            },
            isUsingDeviceEQ: false,
            onUseDeviceEQ: {}
        )
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .background {
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
            .fill(DesignTokens.Colors.recessedBackground)
    }
    .frame(width: 550)
    .padding()
    .background(Color.black)
}
