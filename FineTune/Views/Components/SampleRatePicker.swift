import SwiftUI
import Foundation

struct SampleRatePicker: View {
    struct Option: Identifiable, Hashable {
        let rate: Double
        var id: Int { Int(rate.rounded()) }
    }

    let currentRate: Double
    let availableRates: [Double]
    let canSetRate: Bool
    let canDisconnect: Bool
    let onSelect: (Double) -> Void
    let onDisconnect: () -> Void

    private var options: [Option] {
        let baseRates = availableRates.isEmpty ? [currentRate] : availableRates
        let deduped = Set(baseRates.map { Int($0.rounded()) })
            .map(Double.init)
            .sorted()
        return deduped.map(Option.init(rate:))
    }

    private var selectedOption: Option? {
        if let exact = options.first(where: { abs($0.rate - currentRate) < 1 }) {
            return exact
        }
        return options.first
    }

    private var isInteractive: Bool {
        canSetRate && options.count > 1
    }

    private var isMenuEnabled: Bool {
        isInteractive || canDisconnect
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.rate)
                } label: {
                    if let selected = selectedOption, selected == option {
                        Label(Self.displayText(for: option.rate), systemImage: "checkmark")
                    } else {
                        Text(Self.displayText(for: option.rate))
                    }
                }
            }

            if canDisconnect {
                Divider()
                Button(role: .destructive) {
                    onDisconnect()
                } label: {
                    Label("Disconnect", systemImage: "bolt.horizontal.circle")
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isMenuEnabled ? .secondary : .tertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isMenuEnabled)
        .help("Sample Rate: \(Self.displayText(for: currentRate))")
    }

    static func displayText(for rate: Double) -> String {
        let khz = rate / 1000.0
        if abs(khz.rounded() - khz) < 0.01 {
            return "\(Int(khz.rounded())) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }
}

#Preview("Sample Rate Picker") {
    VStack(spacing: 10) {
        SampleRatePicker(
            currentRate: 48000,
            availableRates: [44100, 48000, 96000],
            canSetRate: true,
            canDisconnect: true,
            onSelect: { _ in },
            onDisconnect: {}
        )

        SampleRatePicker(
            currentRate: 48000,
            availableRates: [48000],
            canSetRate: false,
            canDisconnect: false,
            onSelect: { _ in },
            onDisconnect: {}
        )
    }
    .padding()
    .darkGlassBackground()
}
