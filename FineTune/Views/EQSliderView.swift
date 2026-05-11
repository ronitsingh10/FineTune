// FineTune/Views/EQSliderView.swift
import SwiftUI

struct EQSliderView: View {
    let frequency: String
    @Binding var gain: Float
    let range: ClosedRange<Float> = -12...12

    // Local state for smooth visual updates
    @State private var localGain: Float = 0
    @State private var isDragging: Bool = false

    // Use design tokens for slider style variant support
    private var trackWidth: CGFloat { DesignTokens.Dimensions.sliderTrackHeight }
    private var thumbSize: CGFloat { DesignTokens.Dimensions.sliderThumbSize }
    private let tickCount = 5  // Number of tick marks
    private let tickWidth: CGFloat = 3
    private let tickGap: CGFloat = 3
    private let verticalPadding: CGFloat = 8

    private func formatGain(_ gain: Float) -> String {
        let rounded = Int(gain.rounded())
        return rounded >= 0 ? "+\(rounded)dB" : "\(rounded)dB"
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                // Thumb travels within padded range
                let travelHeight = geo.size.height - (verticalPadding * 2)
                let normalizedGain = CGFloat((localGain - range.lowerBound) / (range.upperBound - range.lowerBound))
                let thumbY = verticalPadding + travelHeight * (1 - normalizedGain)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                // Map touch to padded range
                                let normalizedY = (value.location.y - verticalPadding) / travelHeight
                                let normalized = 1 - normalizedY
                                let clamped = min(max(normalized, 0), 1)
                                let newGain = Float(clamped) * (range.upperBound - range.lowerBound) + range.lowerBound
                                localGain = newGain
                                gain = newGain
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
                    .scrollWheelStep($gain, in: range)
                    .overlay {
                        // All visuals - no hit testing
                        ZStack {
                            // Tick marks on LEFT side
                            VStack(spacing: 0) {
                                ForEach(0..<tickCount, id: \.self) { index in
                                    if index > 0 { Spacer() }
                                    Rectangle()
                                        .fill(DesignTokens.Colors.textTertiary.opacity(0.4))
                                        .frame(width: tickWidth, height: 1)
                                }
                            }
                            .frame(height: travelHeight)
                            .offset(x: -(trackWidth / 2 + tickGap + tickWidth / 2))

                            // Tick marks on RIGHT side
                            VStack(spacing: 0) {
                                ForEach(0..<tickCount, id: \.self) { index in
                                    if index > 0 { Spacer() }
                                    Rectangle()
                                        .fill(DesignTokens.Colors.textTertiary.opacity(0.4))
                                        .frame(width: tickWidth, height: 1)
                                }
                            }
                            .frame(height: travelHeight)
                            .offset(x: trackWidth / 2 + tickGap + tickWidth / 2)

                            // Track (full height)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DesignTokens.Colors.sliderTrack)
                                .frame(width: trackWidth)

                            // Center line (0 dB marker) - spans across ticks
                            Rectangle()
                                .fill(DesignTokens.Colors.unityMarker)
                                .frame(width: trackWidth + (tickGap + tickWidth) * 2, height: 1.5)

                            // Knob-style thumb (themed background with center dot)
                            ZStack {
                                Circle()
                                    .fill(DesignTokens.Colors.thumbBackground)
                                Circle()
                                    .fill(DesignTokens.Colors.thumbDot)
                                    .frame(width: thumbSize * 0.35, height: thumbSize * 0.35)
                            }
                            .frame(width: thumbSize, height: thumbSize)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .position(x: geo.size.width / 2, y: thumbY)

                            // dB value label (appears during drag)
                            if isDragging {
                                Text(formatGain(localGain))
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                                    .fixedSize()
                                    .position(x: geo.size.width / 2, y: thumbY - thumbSize / 2 - 10)
                            }
                        }
                        .allowsHitTesting(false)
                    }
            }

            VStack(spacing: 0) {
                Text(frequency)
                    .font(DesignTokens.Typography.eqLabel)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text("Hz")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .onAppear {
            localGain = gain  // Initialize from binding
        }
        .onChange(of: gain) { _, newValue in
            localGain = newValue  // Sync from external changes
        }
    }
}

#Preview {
    HStack(spacing: 8) {
        EQSliderView(frequency: "32", gain: .constant(6))
        EQSliderView(frequency: "1k", gain: .constant(0))
        EQSliderView(frequency: "16k", gain: .constant(-6))
    }
    .frame(width: 120, height: 120)
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
