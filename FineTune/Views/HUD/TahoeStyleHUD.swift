// FineTune/Views/HUD/TahoeStyleHUD.swift
import SwiftUI

/// 300×72 interactive volume pill with device name, slider, and percentage.
struct TahoeStyleHUD: View {
    let sliderFraction: Float
    let mute: Bool
    let deviceName: String
    var onSliderChange: ((Float) -> Void)? = nil
    var onHoverChange: ((Bool) -> Void)? = nil

    // MARK: - Constants

    static let nameFont: Font = DesignTokens.Typography.rowNameBold

    private static let frameWidth: CGFloat = 300
    private static let frameHeight: CGFloat = 72
    private static let cornerRadius: CGFloat = 22
    private static let percentageWidth: CGFloat = 36

    // MARK: - State

    @State private var dragValue: Double? = nil

    // MARK: - Derived state

    private var displayFloat: Float {
        if let dragValue { return Float(max(0, min(1, dragValue))) }
        return max(0, min(1, sliderFraction))
    }

    private var displayedPercent: Int {
        Int((displayFloat * 100).rounded())
    }

    private var displayMute: Bool {
        if let dragValue { return Int((dragValue * 100).rounded()) == 0 }
        return mute
    }

    private var waveIconName: String {
        switch displayedPercent {
        case 0:        return "speaker.fill"
        case 1...33:   return "speaker.wave.1.fill"
        case 34...66:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    private var percentageText: String {
        "\(displayedPercent)%"
    }

    #if DEBUG
    var waveIconNameForTest: String { waveIconName }
    #endif

    private var accessibilityDescription: String {
        let device = deviceName.isEmpty ? "Unknown device" : deviceName
        let percent = Int((displayFloat * 100).rounded())
        if displayMute { return "\(device), muted, volume at \(percent) percent" }
        return "\(device), volume \(percent) percent"
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(displayFloat) },
            set: { newValue in
                dragValue = newValue
                onSliderChange?(Float(newValue))
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(deviceName.isEmpty ? " " : deviceName)
                .font(Self.nameFont)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                // Hard-swap — symbolEffect(.replace.*) cross-fades the whole wave glyph on every bin change.
                Image(systemName: displayMute ? "speaker.slash.fill" : waveIconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(displayMute
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 18, height: 18, alignment: .center)

                LiquidGlassSlider(
                    value: sliderBinding,
                    in: 0...1,
                    showUnityMarker: false
                )
                .opacity(displayMute ? 0.5 : 1.0)
                .scrollWheelStep(sliderBinding, in: 0.0...1.0)

                Text(percentageText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: Self.percentageWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(DesignTokens.Colors.hudBorder, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onHover { hovering in
            onHoverChange?(hovering)
        }
        .onChange(of: sliderFraction) { _, _ in
            // External source pushed a value; drop the sticky drag snapshot.
            dragValue = nil
        }
        .onChange(of: mute) { _, _ in
            dragValue = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

#Preview("Tahoe — mid volume") {
    TahoeStyleHUD(sliderFraction: 0.5, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — muted") {
    TahoeStyleHUD(sliderFraction: 0.5, mute: true, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — long name") {
    TahoeStyleHUD(sliderFraction: 0.75, mute: false,
                  deviceName: "Ronit's MacBook Pro Speakers (Built-in Audio Output)")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — empty name") {
    TahoeStyleHUD(sliderFraction: 0.25, mute: false, deviceName: "")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — max volume") {
    TahoeStyleHUD(sliderFraction: 1.0, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — zero volume") {
    TahoeStyleHUD(sliderFraction: 0.0, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — light washout") {
    TahoeStyleHUD(sliderFraction: 0.5, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.white)
}
