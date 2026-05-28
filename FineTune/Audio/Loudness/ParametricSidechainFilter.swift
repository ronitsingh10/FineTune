import Foundation

/// A helper Biquad stage using direct-form II transposed structure.
final class BiquadStage {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    func setupPeaking(frequency: Double, gainDB: Float, q: Double, sampleRate: Double) {
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: frequency,
            gainDB: gainDB,
            q: q,
            sampleRate: sampleRate
        )
        b0 = Float(coeffs[0])
        b1 = Float(coeffs[1])
        b2 = Float(coeffs[2])
        a1 = Float(coeffs[3])
        a2 = Float(coeffs[4])
    }

    func setupHighPass(frequency: Double, q: Double, sampleRate: Double) {
        let coeffs = BiquadMath.highPassCoefficients(
            frequency: frequency,
            q: q,
            sampleRate: sampleRate
        )
        b0 = Float(coeffs[0])
        b1 = Float(coeffs[1])
        b2 = Float(coeffs[2])
        a1 = Float(coeffs[3])
        a2 = Float(coeffs[4])
    }

    @inline(__always)
    func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        let nextZ1 = b1 * x - a1 * y + z2
        let nextZ2 = b2 * x - a2 * y
        z1 = nextZ1
        z2 = nextZ2
        return y
    }

    func reset() {
        z1 = 0
        z2 = 0
    }
}

/// Custom parametric EQ sidechain filter mimicking Stereo Tool's preset.
final class ParametricSidechainFilter: @unchecked Sendable {
    private let stages: [BiquadStage]

    init(sampleRate: Float) {
        let sRate = Double(sampleRate)

        // Stage 0: 38 Hz Butterworth High Pass (ITU Bass correction)
        let hp = BiquadStage()
        hp.setupHighPass(frequency: 38.0, q: 1.0 / sqrt(2.0), sampleRate: sRate)

        // Band 1: Gain -12.0 dB, Freq 23 Hz, Q 1.40
        let p1 = BiquadStage()
        p1.setupPeaking(frequency: 23.0, gainDB: -12.0, q: 1.40, sampleRate: sRate)

        // Band 2: Gain 1.0 dB, Freq 160 Hz, Q 1.00
        let p2 = BiquadStage()
        p2.setupPeaking(frequency: 160.0, gainDB: 1.0, q: 1.00, sampleRate: sRate)

        // Band 3: Gain -2.2 dB, Freq 240 Hz, Q 0.51
        let p3 = BiquadStage()
        p3.setupPeaking(frequency: 240.0, gainDB: -2.2, q: 0.51, sampleRate: sRate)

        // Band 4: Gain -8.1 dB, Freq 781 Hz, Q 1.30
        let p4 = BiquadStage()
        p4.setupPeaking(frequency: 781.0, gainDB: -8.1, q: 1.30, sampleRate: sRate)

        // Band 5: Gain 3.5 dB, Freq 1717 Hz, Q 0.63
        let p5 = BiquadStage()
        p5.setupPeaking(frequency: 1717.0, gainDB: 3.5, q: 0.63, sampleRate: sRate)

        // Band 6: Gain -3.7 dB, Freq 10054 Hz, Q 1.74
        let p6 = BiquadStage()
        p6.setupPeaking(frequency: 10054.0, gainDB: -3.7, q: 1.74, sampleRate: sRate)

        self.stages = [hp, p1, p2, p3, p4, p5, p6]
    }

    @inline(__always)
    func processSample(_ sample: Float) -> Float {
        var output = sample
        for stage in stages {
            output = stage.process(output)
        }
        return output
    }

    func reset() {
        for stage in stages {
            stage.reset()
        }
    }
}
