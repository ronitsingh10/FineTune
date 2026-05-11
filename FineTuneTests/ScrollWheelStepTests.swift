import CoreGraphics
import Testing
@testable import FineTune

@Suite("ScrollWheelStep continuous mapping")
struct ScrollWheelStepTests {
    @Test("Precise delta scales linearly by sensitivity")
    func precisePoint() {
        var value: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: 10,
            hasPreciseDeltas: true,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            in: 0.0...1.0
        )
        #expect(abs(value - 0.55) < 1e-9)
    }

    @Test("Non-precise delta normalizes to sign and scales by lineUnits")
    func nonPreciseClick() {
        var value: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: 1,
            hasPreciseDeltas: false,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            lineUnits: 12,
            in: 0.0...1.0
        )
        #expect(abs(value - 0.56) < 1e-9)
    }

    @Test("Non-precise large delta still produces a fixed sign-normalized step")
    func nonPreciseLargeDelta() {
        var value: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: 5,
            hasPreciseDeltas: false,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            lineUnits: 12,
            in: 0.0...1.0
        )
        #expect(abs(value - 0.56) < 1e-9)
    }

    @Test("Negative precise delta decreases value")
    func negativeDelta() {
        var value: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: -10,
            hasPreciseDeltas: true,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            in: 0.0...1.0
        )
        #expect(abs(value - 0.45) < 1e-9)
    }

    @Test("Direction inversion flips the effective sign")
    func directionInversion() {
        var value: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: 10,
            hasPreciseDeltas: true,
            isDirectionInverted: true,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            in: 0.0...1.0
        )
        #expect(abs(value - 0.45) < 1e-9)
    }

    @Test("Momentum tail events are ignored so release freezes the value")
    func momentumDrop() {
        var value: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: 100,
            hasPreciseDeltas: true,
            isDirectionInverted: false,
            isMomentumTail: true,
            value: &value,
            sensitivity: 0.005,
            in: 0.0...1.0
        )
        #expect(value == 0.5)
    }

    @Test("Stepping past the upper bound clamps")
    func clampUpper() {
        var value: Double = 0.95
        ScrollWheelStep.apply(
            deltaY: 100,
            hasPreciseDeltas: true,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            in: 0.0...1.0
        )
        #expect(value == 1.0)
    }

    @Test("Stepping past the lower bound clamps")
    func clampLower() {
        var value: Double = 0.05
        ScrollWheelStep.apply(
            deltaY: -100,
            hasPreciseDeltas: true,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            in: 0.0...1.0
        )
        #expect(value == 0.0)
    }

    @Test("Zero delta is a no-op")
    func zeroDelta() {
        var value: Double = 0.5
        ScrollWheelStep.apply(
            deltaY: 0,
            hasPreciseDeltas: true,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &value,
            sensitivity: 0.005,
            in: 0.0...1.0
        )
        #expect(value == 0.5)
    }

    @Test("Generic path compiles and runs with a Float binding (EQ slider domain)")
    func floatBinding() {
        var gain: Float = 0
        ScrollWheelStep.apply(
            deltaY: 8,
            hasPreciseDeltas: true,
            isDirectionInverted: false,
            isMomentumTail: false,
            value: &gain,
            sensitivity: Float(0.12),
            in: Float(-12)...Float(12)
        )
        #expect(abs(gain - 0.96) < 1e-4)
    }
}
