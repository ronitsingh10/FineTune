// FineTune/Views/Components/BalanceSlider.swift
import SwiftUI

/// Compact L/R stereo balance control matching Liquid Glass device sliders.
/// Double-click the slider (or the center tick) resets to center (0.5).
struct BalanceSlider: View {
    @Binding var balance: Double
    let onEditingChanged: ((Bool) -> Void)?

    init(
        balance: Binding<Double>,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._balance = balance
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text("L")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(width: 10, alignment: .trailing)

            LiquidGlassSlider(
                value: $balance,
                in: 0...1,
                showUnityMarker: true,
                onEditingChanged: onEditingChanged
            )
            .onTapGesture(count: 2) {
                balance = Double(StereoBalance.center)
            }
            .help("Balance — double-click to center")

            Text("R")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(width: 10, alignment: .leading)
        }
        .frame(height: DesignTokens.Dimensions.sliderThumbHeight)
        .accessibilityLabel("Balance")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let b = balance
        if abs(b - 0.5) < 0.01 { return "Center" }
        if b < 0.5 {
            return "Left \(Int(round((0.5 - b) * 200)))%"
        }
        return "Right \(Int(round((b - 0.5) * 200)))%"
    }
}

#Preview("Balance Slider") {
    struct PreviewWrapper: View {
        @State private var balance: Double = 0.5
        var body: some View {
            BalanceSlider(balance: $balance)
                .padding()
                .frame(width: 280)
        }
    }
    return PreviewWrapper()
}
