import Foundation

struct BiquadSection {
    private var b0: Float, b1: Float, b2: Float
    private var a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    init(coefficients: [Double]) {
        precondition(coefficients.count == 5)
        b0 = Float(coefficients[0])
        b1 = Float(coefficients[1])
        b2 = Float(coefficients[2])
        a1 = Float(coefficients[3])
        a2 = Float(coefficients[4])
    }

    @inline(__always)
    mutating func process(_ sample: Float) -> Float {
        let y = b0 * sample + z1
        z1 = b1 * sample - a1 * y + z2
        z2 = b2 * sample - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0; z2 = 0
    }
}

struct LR4Filter {
    private var stage1: BiquadSection
    private var stage2: BiquadSection

    init(lowPass frequency: Double, sampleRate: Double) {
        let q = 1.0 / sqrt(2.0)
        let coeffs1 = BiquadMath.lowPassCoefficients(frequency: frequency, q: q, sampleRate: sampleRate)
        let coeffs2 = BiquadMath.lowPassCoefficients(frequency: frequency, q: q, sampleRate: sampleRate)
        stage1 = BiquadSection(coefficients: coeffs1)
        stage2 = BiquadSection(coefficients: coeffs2)
    }

    init(highPass frequency: Double, sampleRate: Double) {
        let q = 1.0 / sqrt(2.0)
        let coeffs1 = BiquadMath.highPassCoefficients(frequency: frequency, q: q, sampleRate: sampleRate)
        let coeffs2 = BiquadMath.highPassCoefficients(frequency: frequency, q: q, sampleRate: sampleRate)
        stage1 = BiquadSection(coefficients: coeffs1)
        stage2 = BiquadSection(coefficients: coeffs2)
    }

    @inline(__always)
    mutating func process(_ sample: Float) -> Float {
        return stage2.process(stage1.process(sample))
    }

    mutating func reset() {
        stage1.reset(); stage2.reset()
    }
}

struct LinkwitzRileyCrossover2 {
    private var lp4: LR4Filter
    private var hp4: LR4Filter

    init(frequency: Double, sampleRate: Double) {
        lp4 = LR4Filter(lowPass: frequency, sampleRate: sampleRate)
        hp4 = LR4Filter(highPass: frequency, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(_ sample: Float) -> (Float, Float) {
        let low = lp4.process(sample)
        let high = hp4.process(sample)
        return (low, high)
    }

    mutating func reset() {
        lp4.reset()
        hp4.reset()
    }
}
