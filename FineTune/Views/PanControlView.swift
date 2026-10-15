// FineTune/Views/PanControlView.swift
import SwiftUI

/// Per-app stereo pan control shown in an app's expanded panel.
/// Value is -1.0 (full left) … 0.0 (center) … 1.0 (full right).
struct PanControlView: View {
    let pan: Float
    let onPanChange: (Float) -> Void

    @State private var localPan: Double
    @State private var isEditing = false
    @State private var isHovered = false

    /// Values this close to center snap to exactly 0 so "center" is easy to hit.
    private static let centerSnap: Double = 0.04
    private let trackHeight: CGFloat = 4

    init(pan: Float, onPanChange: @escaping (Float) -> Void) {
        self.pan = pan
        self.onPanChange = onPanChange
        self._localPan = State(initialValue: Double(pan))
    }

    static func label(for pan: Double) -> String {
        let percent = Int((abs(pan) * 100).rounded())
        if percent == 0 { return "C" }
        return pan < 0 ? "L\(percent)" : "R\(percent)"
    }

    private var panBinding: Binding<Double> {
        Binding(
            get: { localPan },
            set: { newValue in
                let snapped = abs(newValue) < Self.centerSnap ? 0 : newValue
                localPan = snapped
                onPanChange(Float(snapped))
            }
        )
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Pan")
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(.primary)
                .frame(width: 28, alignment: .leading)

            Text("L")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            track

            Text("R")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Button {
                localPan = 0
                onPanChange(0)
            } label: {
                Text(Self.label(for: localPan))
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(localPan == 0 ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.accentPrimary)
                    .frame(width: 36, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Click to center")
            .accessibilityLabel("Reset pan to center")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .onChange(of: pan) { _, newValue in
            // Sync from parent (URL scheme, settings reset) unless the user is dragging
            if !isEditing { localPan = Double(newValue) }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let center = width / 2
            let offset = CGFloat(localPan) * center

            ZStack {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.Colors.sliderTrack)
                        .frame(height: trackHeight)

                    // Fill grows outward from the center toward the panned side
                    Capsule()
                        .fill(DesignTokens.Colors.accentPrimary)
                        .frame(width: max(trackHeight, abs(offset)), height: trackHeight)
                        .offset(x: offset < 0 ? center + offset : center)
                }
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                Rectangle()
                    .fill(DesignTokens.Colors.unityMarker)
                    .frame(width: 1.5, height: 8)
                    .allowsHitTesting(false)

                Slider(value: panBinding, in: -1...1) { editing in
                    isEditing = editing
                }
                .controlSize(.mini)
                .tint(.clear)
                .opacity(isHovered || isEditing ? 1 : 0.01)
                .accessibilityLabel("Pan")
                .accessibilityValue(Self.label(for: localPan))
            }
        }
        .frame(height: DesignTokens.Dimensions.sliderThumbHeight)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    VStack {
        PanControlView(pan: 0, onPanChange: { _ in })
        PanControlView(pan: -1, onPanChange: { _ in })
        PanControlView(pan: 0.35, onPanChange: { _ in })
    }
    .frame(width: 480)
    .padding()
}
