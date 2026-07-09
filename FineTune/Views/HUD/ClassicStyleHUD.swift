// FineTune/Views/HUD/ClassicStyleHUD.swift
import SwiftUI

/// 200×200 pre-Tahoe-style volume HUD: 80 pt glyph + 16-tile segment row. Stateless.
struct ClassicStyleHUD: View {
    let sliderFraction: Float
    let mute: Bool

    // MARK: - Constants

    static let hasPercentageLabel: Bool = false

    private static let tileCount: Int = 16
    private static let frameSize: CGFloat = 200
    private static let cornerRadius: CGFloat = 16
    private static let iconSize: CGFloat = 80
    private static let tileSize: CGFloat = 7.5
    private static let tileSpacing: CGFloat = 2
    private static let tileSideInset: CGFloat = 20

    // MARK: - Derived state

    private var displayValue: Float {
        mute ? 0 : max(0, min(1, sliderFraction))
    }

    private var displayedPercent: Int {
        Int((displayValue * 100).rounded())
    }

    private var filledTileCount: Int {
        Int((displayValue * Float(Self.tileCount)).rounded())
    }

    private var waveIconName: String {
        switch displayedPercent {
        case 0:        return "speaker.fill"
        case 1...33:   return "speaker.wave.1.fill"
        case 34...66:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    /// `speaker.slash.fill` sits 2pt high vs the rest of the `speaker.*` glyphs at 80pt.
    private var iconYOffset: CGFloat {
        (mute || displayedPercent == 0) ? 2 : 0
    }

    #if DEBUG
    var waveIconNameForTest: String { waveIconName }
    #endif

    private var accessibilityDescription: String {
        if mute { return L10n.string("Muted") }
        return L10n.format("Volume %lld percent", Int((displayValue * 100).rounded()))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            iconSection
            tileSection
        }
        .frame(width: Self.frameSize, height: Self.frameSize)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(DesignTokens.Colors.hudBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var iconSection: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 56)
            // Hard-swap — symbolEffect(.replace.*) cross-fades the whole wave glyph on every bin change.
            Image(systemName: mute ? "speaker.slash.fill" : waveIconName)
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.hudTileActive)
                .offset(y: iconYOffset)
            Spacer()
        }
        .frame(height: 100)
    }

    private var tileSection: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 40)
            HStack(spacing: Self.tileSpacing) {
                Spacer().frame(width: Self.tileSideInset)
                ForEach(0..<Self.tileCount, id: \.self) { index in
                    Rectangle()
                        .fill(index < filledTileCount
                              ? DesignTokens.Colors.hudTileActive
                              : DesignTokens.Colors.hudTileInactive)
                        .frame(width: Self.tileSize, height: Self.tileSize)
                }
                Spacer().frame(width: Self.tileSideInset)
            }
            .animation(DesignTokens.Animation.quick, value: filledTileCount)
        }
        .frame(height: 80)
    }
}

#Preview("Classic — mid volume") {
    ClassicStyleHUD(sliderFraction: 0.5, mute: false)
        .padding()
        .background(Color.black)
}

#Preview("Classic — muted") {
    ClassicStyleHUD(sliderFraction: 0.5, mute: true)
        .padding()
        .background(Color.black)
}

#Preview("Classic — max volume") {
    ClassicStyleHUD(sliderFraction: 1.0, mute: false)
        .padding()
        .background(Color.black)
}

#Preview("Classic — zero volume") {
    ClassicStyleHUD(sliderFraction: 0.0, mute: false)
        .padding()
        .background(Color.black)
}
