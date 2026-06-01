// FineTuneTests/AgcPhonOffsetSmootherTests.swift

import Testing
import Foundation
@testable import FineTune

@Suite("AgcPhonOffsetSmootherTests")
struct AgcPhonOffsetSmootherTests {

    @Test("Initial state is 0 and reset returns state to 0")
    func initialStateAndReset() {
        let smoother = AgcPhonOffsetSmoother(pollIntervalMs: 200)
        #expect(smoother.currentOffset == 0.0)
        
        smoother.process(-10.0)
        #expect(smoother.currentOffset < 0.0)
        
        smoother.reset()
        #expect(smoother.currentOffset == 0.0)
    }

    @Test("Normal slow path coefficients for small changes")
    func slowPathSmoothing() {
        let smoother = AgcPhonOffsetSmoother(pollIntervalMs: 200)
        
        // 1. We manually set a start state. To do that without exposing internal vars,
        // we can run a process step or design math from 0.
        // Let's process a small negative change: 0 to -1.0.
        // delta = -1.0 (gain decreasing).
        // Since abs(delta) = 1.0 <= 6.0, it should use the 10s release coefficient:
        // coeff = 1 - exp(-200 / 10000) = 1 - exp(-0.02) = 0.0198013
        // expected = 0 + coeff * (-1.0) = -0.0198013
        let offset1 = smoother.process(-1.0)
        #expect(abs(offset1 - (-0.0198013)) < 1e-5)
        
        // 2. Now process a small positive change: -0.0198013 to 0.0.
        // delta = 0.0198013 (gain increasing).
        // Since abs(delta) <= 6.0, it should use the 3s attack coefficient:
        // coeff = 1 - exp(-200 / 3000) = 1 - exp(-0.0666667) = 0.0644930
        // expected = -0.0198013 + coeff * (0 - (-0.0198013)) = -0.0198013 + 0.0644930 * 0.0198013 = -0.0185242
        let offset2 = smoother.process(0.0)
        #expect(abs(offset2 - (-0.0185242)) < 1e-5)
    }

    @Test("Fast path coefficients for large jumps (above 6 dB)")
    func fastPathSmoothing() {
        let smoother = AgcPhonOffsetSmoother(pollIntervalMs: 200)
        
        // 1. Large negative jump: 0 to -10.0.
        // delta = -10.0 (gain decreasing).
        // Since abs(delta) = 10.0 > 6.0, it should use the fast release coefficient (3s time constant):
        // coeff = 1 - exp(-200 / 3000) = 0.0644930
        // expected = 0 + 0.0644930 * (-10.0) = -0.644930
        let offset1 = smoother.process(-10.0)
        #expect(abs(offset1 - (-0.644930)) < 1e-5)
        
        // Let's reset.
        smoother.reset()
        
        // 2. To test large positive jump, we first need to establish a negative value.
        // We can force it by doing a large negative jump first, then doing a large positive jump.
        // Let's process -10.0 multiple times to settle it near -10.0.
        for _ in 0..<400 {
            _ = smoother.process(-10.0)
        }
        let settledOffset = smoother.currentOffset
        #expect(settledOffset < -9.5) // should be very close to -10
        
        // Now process a large positive jump to 0.0.
        // delta = 0.0 - settledOffset > 9.5 (> 6.0).
        // Since delta > 6.0, it should use the fast attack coefficient (1s time constant):
        // coeff = 1 - exp(-200 / 1000) = 1 - exp(-0.2) = 0.1812692
        // expected = settledOffset + 0.1812692 * (0.0 - settledOffset)
        let expectedPositiveJumpOffset = settledOffset + 0.1812692 * (0.0 - settledOffset)
        let offset2 = smoother.process(0.0)
        #expect(abs(offset2 - expectedPositiveJumpOffset) < 1e-4)
    }
}
