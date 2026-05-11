import AppKit
import SwiftUI

struct ScrollWheelStepModifier<V: BinaryFloatingPoint>: ViewModifier {
    @Binding var value: V
    let range: ClosedRange<V>
    let sensitivity: V

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    install()
                } else {
                    uninstall()
                }
            }
            .onDisappear { uninstall() }
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            ScrollWheelStep.apply(
                event: event,
                value: &value,
                sensitivity: sensitivity,
                in: range
            )
            return nil
        }
    }

    private func uninstall() {
        if let token = monitor {
            NSEvent.removeMonitor(token)
        }
        monitor = nil
    }
}

extension View {
    /// Smooth scroll-wheel adjustment with a default tuning of "200-pt trackpad swipe ≈ full range."
    func scrollWheelStep<V: BinaryFloatingPoint>(
        _ value: Binding<V>,
        in range: ClosedRange<V>
    ) -> some View {
        let span = range.upperBound - range.lowerBound
        return modifier(ScrollWheelStepModifier(value: value, range: range, sensitivity: span / 200))
    }
}
