import Foundation
import Accelerate

/// RT-safe loudness compensation processor based on ISO 226:2023 equal-loudness contours.
///
/// Applies frequency-dependent gain to counteract the human ear's reduced sensitivity
/// to bass and treble at low listening levels. At the reference level (~80 phon),
/// compensation is flat (bypassed). At lower levels, the contour difference is
/// normalized around 1 kHz so only spectral balance is corrected. The app then fits
/// that target curve with a low-cost four-section shelf/bell cascade.
///
/// ## Headroom
/// The fitted curve is boost-only below ~1 kHz (up to ~+20 dB at low listening levels).
/// Program material is usually mastered close to full scale, so applying that boost to a
/// full-scale signal pushes the low band 8–18 dB above 0 dBFS, and the downstream
/// `SoftLimiter` (a memoryless waveshaper with 0.05 of headroom above its 0.95 threshold)
/// flattens every bass cycle — audible low-frequency distortion.
///
/// The compensator therefore reserves headroom with a single global preamp applied
/// before the cascade. The cut is *dynamic*: it only covers the part of the cascade's
/// peak gain that is not already covered by digital attenuation upstream in the tap
/// (per-app volume slider, software-controlled device volume):
///
///     availableHeadroomDB = max(0, -20·log10(min(digitalGain, 1)))
///     cutDB               = max(0, peakGainDB - availableHeadroomDB)
///
/// Available digital headroom is used for genuine boost. When it fully covers the
/// cascade's peak gain, 1 kHz stays at unity; otherwise only the uncovered deficit
/// attenuates the mid band (at full scale on a hardware-volume device that is the whole
/// peak gain, so the cascade can never exceed unity). The fitted section gains are never
/// modified — the preamp is a pure global offset, so the spectral shape of the
/// compensation is preserved exactly.
///
/// Two inputs drive this, and they are deliberately separate so a per-device policy
/// can later supply them independently:
/// - `listeningVolume` (device × app volume): estimates the listening level in phon.
/// - `digitalGain` (app volume × boost × software device gain): the linear gain already
///   applied inside the tap, i.e. the digital headroom available. Hardware/DDC device
///   volume acts after the DSP and contributes nothing here.
///
/// Subclass of `BiquadProcessor` — inherits atomic setup swaps, stereo biquad processing,
/// delay buffer management, and NaN safety. Follows the same pattern as `EQProcessor`.
final class LoudnessCompensator: BiquadProcessor, @unchecked Sendable {

    // MARK: - Configuration

    /// Four-section topology chosen to approximate the ISO-derived loudness target with
    /// minimal runtime DSP cost: low shelf, low-mid bell, upper-mid bell, high shelf.
    private enum LoudnessFilterKind {
        case lowShelf
        case peaking
        case highShelf
    }

    private struct LoudnessFilterDefinition {
        let kind: LoudnessFilterKind
        let frequency: Double
        let q: Double
    }

    private static let filterDefinitions: [LoudnessFilterDefinition] = [
        .init(kind: .lowShelf, frequency: 80, q: 0.707),
        .init(kind: .peaking, frequency: 180, q: 0.7),
        .init(kind: .peaking, frequency: 3200, q: 0.7),
        .init(kind: .highShelf, frequency: 10000, q: 0.85),
    ]
    static let bandFrequencies = filterDefinitions.map(\.frequency)
    static let bandCount = filterDefinitions.count

    private static let fitGridPointCount = 96
    private static let fitIterationCount = 3

    // MARK: - State

    /// Phon level used for the last coefficient computation.
    private var _currentPhon: Double = 80.0

    /// Peak realized gain (dB, ≥ 0) of the current cascade. 0 when bypassed.
    private var _currentPeakGainDB: Float = 0.0

    /// Last digital gain passed to `update(listeningVolume:digitalGain:)`.
    private var _lastDigitalGain: Float = 1.0

    /// Linear preamp gain applied before the biquad cascade. Written on the main
    /// thread; read by the RT thread in `preProcess`.
    ///
    /// The preamp scalar and the biquad setup are independent stores, and the preamp
    /// follows the tap's volume ramp *target* (`digitalGain`), not the ramped value the
    /// RT path is applying at this instant. During volume, boost and routing changes the
    /// three can therefore be momentarily mismatched; those transients are bounded by
    /// the tap's ~150 ms volume ramp and land in the downstream SoftLimiter. The headroom
    /// guarantee of this processor is a steady-state guarantee only.
    private nonisolated(unsafe) var _preampGain: Float = 1.0

    /// Peak realized gain (dB, ≥ 0) of the current cascade before the preamp. Main thread only.
    var currentPeakGainDB: Float { _currentPeakGainDB }

    /// Attenuation (dB, ≥ 0) currently applied by the preamp. Main thread only.
    private(set) var currentPreampCutDB: Float = 0.0

    /// Linear preamp gain currently applied. Main thread only (diagnostic/tests).
    var currentPreampGain: Float { _preampGain }

    // MARK: - Init

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: Self.bandCount,
            category: "LoudnessCompensator",
            initiallyEnabled: false
        )
    }

    // MARK: - Volume Update

    /// Update compensation for a new listening level and digital headroom.
    ///
    /// - Parameters:
    ///   - listeningVolume: Estimated listening level in 0…1 (device volume × per-app
    ///     slider). Converted to phon; drives the shape and amount of compensation.
    ///   - digitalGain: Linear gain already applied inside the tap before this processor
    ///     (per-app slider × boost × software device gain). Values below 1.0 provide
    ///     digital headroom that the compensation boost can use without a preamp cut;
    ///     values above 1.0 provide none (the downstream limiter handles that case).
    ///
    /// Skips the coefficient rebuild if phon changed by less than 1.0 (coalesces rapid
    /// slider drags) but always refreshes the preamp, which is a single scalar store.
    /// Bypasses the processor (and clears the preamp) at the reference level.
    ///
    /// - Important: **Main thread only.** This method mutates `_eqSetup`, `_isEnabled`
    ///   and `_preampGain`, which the RT audio callback reads via `nonisolated(unsafe)`.
    ///   Calling from any other thread creates a data race. Not annotated `@MainActor`
    ///   because `BiquadProcessor` is not actor-isolated and test call sites run on
    ///   arbitrary Swift Testing threads.
    func update(listeningVolume: Float, digitalGain: Float) {
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: listeningVolume)
        _lastDigitalGain = digitalGain

        // Coalesce rapid updates, but never skip a disabled processor because re-enabling
        // loudness from the UI must rebuild coefficients immediately even at the same volume.
        if isEnabled && abs(phon - _currentPhon) < 1.0 {
            // Coefficients stay; only the digital headroom may have changed.
            applyPreamp(cutDB: Self.preampCutDB(peakGainDB: _currentPeakGainDB, digitalGain: digitalGain))
            return
        }
        _currentPhon = phon

        let gains = computeBandGains(phon: phon)

        // Bypass when all gains are negligible (near reference level)
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 }
        if allNegligible {
            setEnabled(false)
            swapSetup(nil)
            _currentPeakGainDB = 0.0
            applyPreamp(cutDB: 0.0)
            return
        }

        let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(Self.bandCount))
        }
        _currentPeakGainDB = Self.peakRealizedGainDB(sectionGains: gains, sampleRate: sampleRate)
        // Store the preamp before the setup swap so no buffer runs the new cascade
        // without its cut (see `_preampGain` for the transient mismatch window).
        applyPreamp(cutDB: Self.preampCutDB(peakGainDB: _currentPeakGainDB, digitalGain: digitalGain))
        swapSetup(newSetup)
        setEnabled(true)
    }

    /// Store the preamp for a given cut (dB, ≥ 0). Main thread only.
    private func applyPreamp(cutDB: Float) {
        currentPreampCutDB = cutDB
        _preampGain = cutDB > 0 ? powf(10.0, -cutDB / 20.0) : 1.0
    }

    // MARK: - Headroom Math

    /// Digital headroom (dB, ≥ 0) provided by gain already applied upstream in the tap.
    ///
    /// Gain above unity (per-app boost) yields no headroom rather than negative headroom:
    /// the compensator only accounts for its own boost, and over-unity input remains the
    /// downstream limiter's responsibility exactly as before.
    ///
    /// Scope boundary: `digitalGain` is the tap's volume stage only. Manual EQ, AutoEQ
    /// (without its preamp) and the loudness equalizer run between that stage and this
    /// processor and can consume part of the credited headroom; the guarantee here is
    /// that the compensator itself never adds boost beyond the headroom present at its
    /// input from the volume stage. Upstream boost → SoftLimiter is unchanged from today.
    static func availableHeadroomDB(digitalGain: Float) -> Float {
        guard digitalGain > 0, digitalGain < 1.0 else { return 0.0 }
        return -20.0 * log10f(digitalGain)
    }

    /// Preamp attenuation (dB, ≥ 0) needed so the cascade never exceeds unity: the part
    /// of the peak gain that upstream digital attenuation does not already cover.
    static func preampCutDB(peakGainDB: Float, digitalGain: Float) -> Float {
        max(0.0, peakGainDB - availableHeadroomDB(digitalGain: digitalGain))
    }

    /// Maximum realized gain (dB, ≥ 0) of the fitted cascade across the fit grid (20 Hz–20 kHz).
    ///
    /// Evaluated on the realized four-section response rather than the raw ISO target,
    /// since the fit can over- or undershoot the target slightly.
    static func peakRealizedGainDB(sectionGains: [Float], sampleRate: Double) -> Float {
        let realized = realizedResponseDB(sectionGains: sectionGains.map(Double.init), sampleRate: sampleRate)
        return Float(max(0.0, realized.max() ?? 0.0))
    }

    // MARK: - Coefficient Computation

    /// Compute per-section gains (dB) for the fixed four-filter loudness topology.
    private func computeBandGains(phon: Double) -> [Float] {
        Self.fittedSectionGains(forPhon: phon, sampleRate: sampleRate)
    }

    /// Fit the fixed four-section loudness topology to the ISO-derived target curve.
    static func fittedSectionGains(forPhon phon: Double, sampleRate: Double) -> [Float] {
        let targetCurve = targetCurveDB(forPhon: phon)
        let basisResponses = basisResponsesDB(sampleRate: sampleRate)
        let gramMatrix = gramMatrix(for: basisResponses)

        var sectionGains = [Double](repeating: 0.0, count: bandCount)
        for _ in 0..<fitIterationCount {
            let realized = realizedResponseDB(sectionGains: sectionGains, sampleRate: sampleRate)
            let residual = zip(targetCurve, realized).map { target, fitted in
                target - fitted
            }
            let rhs = basisResponses.map { basis in
                zip(basis, residual).reduce(0.0) { partial, pair in
                    partial + pair.0 * pair.1
                }
            }
            guard let delta = solveLinearSystem(gramMatrix, rhs: rhs) else { break }
            for index in 0..<bandCount {
                sectionGains[index] += delta[index]
            }
        }

        return sectionGains.map(Float.init)
    }

    /// Build the flat coefficient array for `vDSP_biquad_CreateSetup`.
    static func coefficientsForBands(gains: [Float], sampleRate: Double) -> [Double] {
        guard gains.count == bandCount else {
            return (0..<bandCount).flatMap { _ in [1.0, 0.0, 0.0, 0.0, 0.0] }
        }

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(bandCount * 5)
        for (index, filter) in filterDefinitions.enumerated() {
            guard filter.frequency < sampleRate / 2.0 else {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }
            let coeffs: [Double]
            switch filter.kind {
            case .lowShelf:
                coeffs = BiquadMath.lowShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: gains[index],
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .peaking:
                coeffs = BiquadMath.peakingEQCoefficients(
                    frequency: filter.frequency,
                    gainDB: gains[index],
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .highShelf:
                coeffs = BiquadMath.highShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: gains[index],
                    q: filter.q,
                    sampleRate: sampleRate
                )
            }
            allCoeffs.append(contentsOf: coeffs)
        }
        return allCoeffs
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        // Called by updateSampleRate() — recompute for current phon at new sample rate
        let gains = computeBandGains(phon: _currentPhon)
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 }
        guard !allNegligible else { return nil }
        let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        // The realized peak depends on the sample rate (bilinear warping), so the preamp
        // follows the recomputed cascade.
        _currentPeakGainDB = Self.peakRealizedGainDB(sectionGains: gains, sampleRate: sampleRate)
        applyPreamp(cutDB: Self.preampCutDB(peakGainDB: _currentPeakGainDB, digitalGain: _lastDigitalGain))
        return (coefficients, Self.bandCount)
    }

    /// Apply the headroom preamp before the biquad cascade (RT-safe: one vDSP multiply,
    /// skipped entirely when no cut is needed).
    override func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var preamp = _preampGain
        guard preamp != 1.0 else { return }
        vDSP_vsmul(output, 1, &preamp, output, 1, vDSP_Length(frameCount * 2))
    }

    private static func cascadeMagnitude(coefficients: [Double], sectionCount: Int, omega: Double) -> Double {
        let cosW = cos(omega)
        let sinW = sin(omega)
        let cos2W = cos(2.0 * omega)
        let sin2W = sin(2.0 * omega)

        var magnitude = 1.0
        for offset in stride(from: 0, to: sectionCount * 5, by: 5) {
            let numeratorReal = coefficients[offset] + coefficients[offset + 1] * cosW + coefficients[offset + 2] * cos2W
            let numeratorImag = -(coefficients[offset + 1] * sinW + coefficients[offset + 2] * sin2W)
            let denominatorReal = 1.0 + coefficients[offset + 3] * cosW + coefficients[offset + 4] * cos2W
            let denominatorImag = -(coefficients[offset + 3] * sinW + coefficients[offset + 4] * sin2W)

            let numeratorMagnitudeSquared = numeratorReal * numeratorReal + numeratorImag * numeratorImag
            let denominatorMagnitudeSquared = denominatorReal * denominatorReal + denominatorImag * denominatorImag
            magnitude *= sqrt(numeratorMagnitudeSquared / denominatorMagnitudeSquared)
        }

        return magnitude
    }

    private static func targetCurveDB(forPhon phon: Double) -> [Double] {
        let compensation = ISO226Contours.compensationGains(atPhon: phon)
        let fitFrequencies = fitGridFrequencies()
        return fitFrequencies.map { frequency in
            ISO226Contours.interpolateCompensation(compensation, atFrequency: frequency)
        }
    }

    private static func basisResponsesDB(sampleRate: Double) -> [[Double]] {
        let fitFrequencies = fitGridFrequencies()
        return filterDefinitions.map { filter in
            let coefficients: [Double]
            switch filter.kind {
            case .lowShelf:
                coefficients = BiquadMath.lowShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: 1.0,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .peaking:
                coefficients = BiquadMath.peakingEQCoefficients(
                    frequency: filter.frequency,
                    gainDB: 1.0,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .highShelf:
                coefficients = BiquadMath.highShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: 1.0,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            }

            return fitFrequencies.map { frequency in
                let omega = 2.0 * Double.pi * frequency / sampleRate
                return 20.0 * log10(cascadeMagnitude(coefficients: coefficients, sectionCount: 1, omega: omega))
            }
        }
    }

    /// Realized cascade response (dB) on the fit grid. Internal for headroom tests.
    static func realizedResponseDB(sectionGains: [Double], sampleRate: Double) -> [Double] {
        let coefficients = coefficientsForBands(gains: sectionGains.map(Float.init), sampleRate: sampleRate)
        return fitGridFrequencies().map { frequency in
            let omega = 2.0 * Double.pi * frequency / sampleRate
            return 20.0 * log10(cascadeMagnitude(coefficients: coefficients, sectionCount: bandCount, omega: omega))
        }
    }

    /// Log-spaced fit grid, 20 Hz–20 kHz. Internal for headroom tests.
    static func fitGridFrequencies() -> [Double] {
        (0..<fitGridPointCount).map { index in
            20.0 * pow(20_000.0 / 20.0, Double(index) / Double(fitGridPointCount - 1))
        }
    }

    private static func gramMatrix(for basisResponses: [[Double]]) -> [[Double]] {
        (0..<bandCount).map { row in
            (0..<bandCount).map { column in
                zip(basisResponses[row], basisResponses[column]).reduce(0.0) { partial, pair in
                    partial + pair.0 * pair.1
                }
            }
        }
    }

    private static func solveLinearSystem(_ matrix: [[Double]], rhs: [Double]) -> [Double]? {
        var augmented = matrix.enumerated().map { index, row in
            row + [rhs[index]]
        }
        let size = rhs.count

        for pivotIndex in 0..<size {
            let bestPivotIndex = (pivotIndex..<size).max { lhs, rhsIndex in
                abs(augmented[lhs][pivotIndex]) < abs(augmented[rhsIndex][pivotIndex])
            } ?? pivotIndex

            guard abs(augmented[bestPivotIndex][pivotIndex]) > 1e-12 else {
                return nil
            }

            if bestPivotIndex != pivotIndex {
                augmented.swapAt(bestPivotIndex, pivotIndex)
            }

            let pivot = augmented[pivotIndex][pivotIndex]
            for column in pivotIndex...size {
                augmented[pivotIndex][column] /= pivot
            }

            for row in 0..<size where row != pivotIndex {
                let factor = augmented[row][pivotIndex]
                guard factor != 0 else { continue }
                for column in pivotIndex...size {
                    augmented[row][column] -= factor * augmented[pivotIndex][column]
                }
            }
        }

        return (0..<size).map { augmented[$0][size] }
    }

}
