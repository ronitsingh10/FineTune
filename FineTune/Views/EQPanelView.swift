// FineTune/Views/EQPanelView.swift
import SwiftUI

struct EQPanelView: View {
    @Binding var settings: EQSettings
    let onPresetSelected: (EQPreset) -> Void
    let onSettingsChanged: (EQSettings) -> Void
    let isUsingDeviceEQ: Bool
    let onUseDeviceEQ: (() -> Void)?

    private let frequencyLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    private var currentPreset: EQPreset? {
        EQPreset.allCases.first { preset in
            preset.settings.bandGains == settings.bandGains
        }
    }

    var body: some View {
        // Entire EQ panel content inside recessed background
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
                    Text("EQ")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundColor(.primary)
                }
                .padding(.leading, -8)

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
        .padding(.horizontal, 0)
        .padding(.vertical, 2)
        // No outer background - parent ExpandableGlassRow provides the glass container
    }
}

#Preview {
    // Simulating how it appears inside ExpandableGlassRow
    VStack {
        EQPanelView(
            settings: .constant(EQSettings()),
            onPresetSelected: { _ in },
            onSettingsChanged: { _ in },
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
