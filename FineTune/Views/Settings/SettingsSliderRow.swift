// FineTune/Views/Settings/SettingsSliderRow.swift
import SwiftUI

/// Settings row with a slider control and editable percentage display
struct SettingsSliderRow: View {
    let icon: String
    let title: String
    let description: String?
    @Binding var value: Float
    let range: ClosedRange<Float>

    /// Double range derived from Float range
    private var doubleRange: ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    init(
        icon: String,
        title: String,
        description: String? = nil,
        value: Binding<Float>,
        range: ClosedRange<Float> = 0...1
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self._value = value
        self.range = range
    }

    var body: some View {
        SettingsRowView(icon: icon, title: title, description: description) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Float($0) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                )
                .frame(width: DesignTokens.Dimensions.settingsSliderWidth)

                EditablePercentage(
                    sliderValue: Binding(
                        get: { Double(value) },
                        set: { value = Float($0) }
                    ),
                    range: doubleRange,
                    useLogScale: false
                )
                .frame(width: DesignTokens.Dimensions.settingsPercentageWidth, alignment: .trailing)
            }
        }
    }
}

// MARK: - Previews

#Preview("Slider Rows") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SettingsSliderRow(
            icon: "speaker.wave.2",
            title: "Default Volume",
            description: "Initial volume for new apps",
            value: .constant(1.0),
            range: 0.1...1.0
        )

        SettingsSliderRow(
            icon: "speaker.wave.3",
            title: "Max Volume Boost",
            description: "Safety limit for volume slider",
            value: .constant(2.0),
            range: 1.0...4.0
        )
    }
    .padding()
    .frame(width: 450)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
