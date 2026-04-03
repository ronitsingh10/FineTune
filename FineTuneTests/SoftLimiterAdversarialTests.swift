// FineTuneTests/SoftLimiterAdversarialTests.swift
// Adversarial tests for SoftLimiter.
// Targets: output ceiling guarantee, monotonicity, continuity,
// odd symmetry, compression curve shape, edge inputs (NaN, Inf, subnormal),
// and processBuffer integration.

import Testing
@testable import FineTune

// MARK: - Output Ceiling Guarantee

@Suite("SoftLimiter — Output Ceiling Guarantee (Adversarial)")
struct SoftLimiterCeilingTests {

    @Test("Output never exceeds +ceiling for positive inputs",
          arguments: [Float(0.96), 1.0, 1.5, 2.0, 5.0, 10.0, 100.0, 1000.0, 1e10, 1e20,
                      Float.greatestFiniteMagnitude])
    func positiveCeiling(input: Float) {
        let output = SoftLimiter.apply(input)
        #expect(output <= SoftLimiter.ceiling,
                "Output \(output) exceeds ceiling for input \(input)")
        #expect(output > 0, "Positive input \(input) must produce positive output")
    }

    @Test("Output never exceeds -ceiling for negative inputs",
          arguments: [Float(-0.96), -1.0, -1.5, -5.0, -100.0, -1e20,
                      -Float.greatestFiniteMagnitude])
    func negativeCeiling(input: Float) {
        let output = SoftLimiter.apply(input)
        #expect(output >= -SoftLimiter.ceiling,
                "Output \(output) exceeds -ceiling for input \(input)")
        #expect(output < 0, "Negative input \(input) must produce negative output")
    }

    @Test("Passthrough is bit-exact at and below threshold",
          arguments: [Float(0.0), 0.001, 0.1, 0.5, 0.9, 0.94, 0.949, 0.95,
                      Float(-0.5), -0.9, -0.95])
    func passthroughBitExact(value: Float) {
        let output = SoftLimiter.apply(value)
        #expect(output == value,
                "At/below threshold, output must be bit-exact: input=\(value) output=\(output)")
    }

    @Test("Output strictly below ceiling for moderate inputs above threshold",
          arguments: [Float(0.96), 1.0, 2.0, 10.0, 100.0, 1000.0])
    func strictlyBelowCeiling(input: Float) {
        // For very large inputs (>~20000), Float32 precision causes output to round
        // to exactly ceiling. This is fine — the guarantee "never exceeds" still holds.
        // This test verifies strict-below for moderate inputs.
        let output = SoftLimiter.apply(input)
        #expect(output < SoftLimiter.ceiling,
                "Moderate input \(input) should produce output < ceiling, got \(output)")
    }
}

// MARK: - Mathematical Properties

@Suite("SoftLimiter — Mathematical Properties (Adversarial)")
struct SoftLimiterPropertiesTests {

    @Test("Monotonicity: larger positive input -> larger or equal output")
    func monotonicityPositive() {
        let inputs: [Float] = [0.0, 0.5, 0.94, 0.95, 0.951, 0.96, 1.0, 1.5, 2.0, 5.0, 10.0, 100.0]
        for i in 0..<(inputs.count - 1) {
            let out1 = SoftLimiter.apply(inputs[i])
            let out2 = SoftLimiter.apply(inputs[i + 1])
            #expect(out2 >= out1,
                    "Monotonicity: f(\(inputs[i]))=\(out1) > f(\(inputs[i+1]))=\(out2)")
        }
    }

    @Test("Monotonicity: more negative input -> more negative output")
    func monotonicityNegative() {
        let inputs: [Float] = [-100.0, -10.0, -2.0, -1.0, -0.96, -0.95, -0.5, 0.0]
        for i in 0..<(inputs.count - 1) {
            let out1 = SoftLimiter.apply(inputs[i])
            let out2 = SoftLimiter.apply(inputs[i + 1])
            #expect(out2 >= out1,
                    "Monotonicity (neg): f(\(inputs[i]))=\(out1) > f(\(inputs[i+1]))=\(out2)")
        }
    }

    @Test("Continuity at threshold: values just above and at threshold are close")
    func continuityAtThreshold() {
        let atThreshold = SoftLimiter.apply(SoftLimiter.threshold)
        let justAbove = SoftLimiter.apply(SoftLimiter.threshold + 1e-6)
        let delta = abs(justAbove - atThreshold)
        #expect(delta < 1e-4,
                "Discontinuity at threshold: f(0.95)=\(atThreshold), f(0.950001)=\(justAbove), delta=\(delta)")
    }

    @Test("Derivative continuity at threshold (smooth transition, no kink)")
    func derivativeContinuityAtThreshold() {
        // Left derivative at threshold: d/dx of passthrough = 1.0
        // Right derivative at threshold: headroom^2 / (0 + headroom)^2 = 1.0
        let h: Float = 1e-4
        let leftDeriv = (SoftLimiter.apply(SoftLimiter.threshold) -
                         SoftLimiter.apply(SoftLimiter.threshold - h)) / h
        let rightDeriv = (SoftLimiter.apply(SoftLimiter.threshold + h) -
                          SoftLimiter.apply(SoftLimiter.threshold)) / h
        #expect(abs(leftDeriv - 1.0) < 0.01,
                "Left derivative at threshold should be ~1.0, got \(leftDeriv)")
        #expect(abs(rightDeriv - 1.0) < 0.01,
                "Right derivative at threshold should be ~1.0, got \(rightDeriv)")
    }

    @Test("Odd symmetry: f(-x) == -f(x) for all x",
          arguments: [Float(0.0), 0.5, 0.95, 0.96, 1.0, 2.0, 10.0, 100.0])
    func oddSymmetry(x: Float) {
        let pos = SoftLimiter.apply(x)
        let neg = SoftLimiter.apply(-x)
        #expect(pos == -neg,
                "Odd symmetry violated: f(\(x))=\(pos), f(-\(x))=\(neg), -f(\(x))=\(-pos)")
    }

    @Test("Sign preservation: output sign matches input sign",
          arguments: [Float(0.001), 0.5, 0.95, 1.0, 100.0])
    func signPreservation(x: Float) {
        #expect(SoftLimiter.apply(x) > 0, "Positive \(x) -> positive output")
        #expect(SoftLimiter.apply(-x) < 0, "Negative \(-x) -> negative output")
    }

    @Test("Compression ratio increases with level (derivative decreasing above threshold)")
    func decreasingDerivative() {
        // Capped at 5.0 — beyond that, Float32 precision makes adjacent outputs
        // indistinguishable, yielding zero numerical derivative.
        let inputs: [Float] = [0.96, 1.0, 1.5, 2.0, 5.0]
        let dx: Float = 0.01
        var prevDeriv: Float = .infinity
        for x in inputs {
            let deriv = (SoftLimiter.apply(x + dx) - SoftLimiter.apply(x)) / dx
            #expect(deriv > 0, "Derivative must be positive (monotonic) at \(x)")
            #expect(deriv < prevDeriv,
                    "Derivative should decrease: at \(x) got \(deriv), prev=\(prevDeriv)")
            prevDeriv = deriv
        }
    }

    @Test("Zero passes through unchanged")
    func zeroPassthrough() {
        #expect(SoftLimiter.apply(0) == 0)
    }

    @Test("Asymptotic approach: output converges toward ceiling as input grows")
    func asymptoticConvergence() {
        // Use moderate values where Float32 precision preserves the gap to ceiling.
        // Above ~20000, Float32 rounds the output to exactly ceiling.
        let outputs = [2.0, 10.0, 100.0, 1000.0].map { SoftLimiter.apply(Float($0)) }
        for i in 0..<(outputs.count - 1) {
            let gap1 = SoftLimiter.ceiling - outputs[i]
            let gap2 = SoftLimiter.ceiling - outputs[i + 1]
            #expect(gap2 < gap1,
                    "Gap to ceiling should shrink: gap[\(i)]=\(gap1), gap[\(i+1)]=\(gap2)")
            #expect(gap2 > 0,
                    "Output must stay below ceiling for moderate input")
        }
    }
}

// MARK: - Edge Inputs

@Suite("SoftLimiter — Edge Inputs (Adversarial)")
struct SoftLimiterEdgeTests {

    @Test("NaN input produces NaN output (not silent corruption to a valid sample)")
    func nanInput() {
        let output = SoftLimiter.apply(.nan)
        // NaN enters compression (abs(NaN) <= threshold is false).
        // overshoot = NaN, overshoot/(overshoot+headroom) = NaN/NaN = NaN.
        // The NaN propagates. This is acceptable: BiquadProcessor has a NaN safety net.
        #expect(output.isNaN, "NaN input should produce NaN output, got \(output)")
    }

    @Test("+Infinity input produces NaN (infinity/infinity in compression formula)")
    func positiveInfinity() {
        let output = SoftLimiter.apply(.infinity)
        // overshoot = Inf, compressed = threshold + headroom * (Inf / (Inf + headroom))
        // Inf / Inf = NaN per IEEE 754. Output = NaN.
        // Documented guarantee is "for any FINITE input" — infinity is not finite.
        // BiquadProcessor's NaN safety net catches this downstream.
        #expect(output.isNaN, "+Inf produces NaN due to Inf/Inf, got \(output)")
    }

    @Test("-Infinity input produces NaN")
    func negativeInfinity() {
        let output = SoftLimiter.apply(-.infinity)
        #expect(output.isNaN, "-Inf produces NaN due to Inf/Inf, got \(output)")
    }

    @Test("Subnormal input passes through unchanged")
    func subnormalInput() {
        let subnormal = Float.leastNonzeroMagnitude
        #expect(SoftLimiter.apply(subnormal) == subnormal)
        #expect(SoftLimiter.apply(-subnormal) == -subnormal)
    }

    @Test("Constants are self-consistent")
    func constantsConsistent() {
        #expect(SoftLimiter.threshold == 0.95)
        #expect(SoftLimiter.ceiling == 1.0)
        #expect(SoftLimiter.headroom == SoftLimiter.ceiling - SoftLimiter.threshold)
        // Float32 can't represent 0.05 exactly: 1.0 - 0.95 = 0.050000012
        #expect(abs(SoftLimiter.headroom - 0.05) < 1e-6,
                "Headroom should be ~0.05, got \(SoftLimiter.headroom)")
    }
}

// MARK: - processBuffer Integration

@Suite("SoftLimiter — processBuffer (Adversarial)")
struct SoftLimiterBufferTests {

    @Test("Buffer entirely below threshold: fast path, all samples unchanged")
    func bufferBelowThreshold() {
        let count = 8
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }
        let values: [Float] = [0.1, -0.1, 0.5, -0.5, 0.9, -0.9, 0.94, -0.94]
        for i in 0..<count { buffer[i] = values[i] }

        SoftLimiter.processBuffer(buffer, sampleCount: count)

        for i in 0..<count {
            #expect(buffer[i] == values[i],
                    "Sample \(i) should be unchanged below threshold")
        }
    }

    @Test("Buffer with peak above threshold: above-threshold samples limited, below unchanged")
    func bufferMixedLevels() {
        let count = 8
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }
        buffer[0] = 0.5;  buffer[1] = -0.5   // Below threshold
        buffer[2] = 2.0;  buffer[3] = -2.0   // Above threshold
        buffer[4] = 0.3;  buffer[5] = -0.3   // Below threshold
        buffer[6] = 1.5;  buffer[7] = -1.5   // Above threshold

        SoftLimiter.processBuffer(buffer, sampleCount: count)

        // Below-threshold samples pass through unchanged
        #expect(buffer[0] == 0.5)
        #expect(buffer[1] == -0.5)
        #expect(buffer[4] == 0.3)
        #expect(buffer[5] == -0.3)
        // Above-threshold samples are limited to within ceiling
        #expect(buffer[2] > 0 && buffer[2] <= SoftLimiter.ceiling)
        #expect(buffer[3] < 0 && buffer[3] >= -SoftLimiter.ceiling)
        #expect(buffer[6] > 0 && buffer[6] <= SoftLimiter.ceiling)
        #expect(buffer[7] < 0 && buffer[7] >= -SoftLimiter.ceiling)
    }

    @Test("processBuffer: exactly at threshold is not modified")
    func bufferExactlyAtThreshold() {
        let count = 2
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }
        buffer[0] = SoftLimiter.threshold
        buffer[1] = -SoftLimiter.threshold

        SoftLimiter.processBuffer(buffer, sampleCount: count)

        // vDSP_maxmgv peak = 0.95 which is NOT > threshold, so fast path returns
        #expect(buffer[0] == SoftLimiter.threshold, "Exact threshold should pass through")
        #expect(buffer[1] == -SoftLimiter.threshold)
    }

    @Test("processBuffer: large buffer with impulse spike")
    func bufferImpulseSpike() {
        let count = 1024
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }
        // All zeros except one impulse
        for i in 0..<count { buffer[i] = 0.0 }
        buffer[512] = 5.0

        SoftLimiter.processBuffer(buffer, sampleCount: count)

        // The spike should be limited
        #expect(buffer[512] > 0 && buffer[512] <= SoftLimiter.ceiling,
                "Impulse spike should be limited: got \(buffer[512])")
        // Zeros should remain zero
        #expect(buffer[0] == 0.0)
        #expect(buffer[511] == 0.0)
        #expect(buffer[513] == 0.0)
    }

    @Test("processBuffer: buffer of all max-value samples")
    func bufferAllMaxValue() {
        let count = 64
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }
        for i in 0..<count { buffer[i] = Float.greatestFiniteMagnitude }

        SoftLimiter.processBuffer(buffer, sampleCount: count)

        for i in 0..<count {
            #expect(buffer[i] <= SoftLimiter.ceiling,
                    "Sample \(i) should be <= ceiling after limiting")
        }
    }
}
