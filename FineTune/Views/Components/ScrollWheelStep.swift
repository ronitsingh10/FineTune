import AppKit

enum ScrollWheelStep {
    static func apply<V: BinaryFloatingPoint>(
        deltaY: CGFloat,
        hasPreciseDeltas: Bool,
        isDirectionInverted: Bool,
        isMomentumTail: Bool,
        value: inout V,
        sensitivity: V,
        lineUnits: V = 10,
        in range: ClosedRange<V>
    ) {
        // Drop the post-flick kinetic tail; releasing the trackpad must freeze the slider.
        guard !isMomentumTail else { return }
        guard deltaY != 0 else { return }

        var delta = deltaY
        if !hasPreciseDeltas {
            // Legacy mouse-wheel deltas are in line units and arrive with AppKit's
            // acceleration applied. Collapse to ±1 so every detent moves a fixed amount.
            delta = delta > 0 ? CGFloat(lineUnits) : -CGFloat(lineUnits)
        }
        if isDirectionInverted {
            delta = -delta
        }

        let next = value + V(delta) * sensitivity
        value = min(range.upperBound, max(range.lowerBound, next))
    }

    static func apply<V: BinaryFloatingPoint>(
        event: NSEvent,
        value: inout V,
        sensitivity: V,
        lineUnits: V = 10,
        in range: ClosedRange<V>
    ) {
        apply(
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            isMomentumTail: event.momentumPhase != [],
            value: &value,
            sensitivity: sensitivity,
            lineUnits: lineUnits,
            in: range
        )
    }
}
