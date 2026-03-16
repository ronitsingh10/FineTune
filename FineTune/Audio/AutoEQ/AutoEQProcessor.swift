// FineTune/Audio/AutoEQ/AutoEQProcessor.swift
import Foundation
import Accelerate

/// RT-safe parametric EQ processor for AutoEQ headphone correction.
///
/// Subclass of `BiquadProcessor` — inherits delay buffer management, atomic setup swaps,
/// stereo biquad processing, and NaN safety. This class adds AutoEQ-specific profile
/// management and a preamp gain stage applied before the biquad cascade.
final class AutoEQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Currently applied profile (needed for sample rate recalculation)
    private var _currentProfile: AutoEQProfile?

    /// Preamp gain in linear scale (RT-safe atomic read in process)
    private nonisolated(unsafe) var _preampGain: Float = 1.0

    /// Number of active filter sections (diagnostic)
    private nonisolated(unsafe) var _filterCount: UInt = 0

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: AutoEQProfile.maxFilters,
            category: "AutoEQProcessor"
        )
    }

    // MARK: - Profile Update

    /// Update the correction profile (call from main thread).
    /// Pass `nil` to disable correction.
    func updateProfile(_ profile: AutoEQProfile?) {
        dispatchPrecondition(condition: .onQueue(.main))
        _currentProfile = profile

        guard let profile = profile, !profile.filters.isEmpty else {
            // Disable: atomic writes
            setEnabled(false)
            _filterCount = 0
            _preampGain = 1.0
            swapSetup(nil)
            return
        }

        let filters = profile.filters
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: sampleRate,
            profileOptimizedRate: profile.optimizedSampleRate
        )

        guard let newSetup = coefficients.withUnsafeBufferPointer({ ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(filters.count))
        }) else {
            // Keep the previous profile active — don't break working audio
            logger.warning("vDSP_biquad_CreateSetup returned nil for \(filters.count) filters — skipping profile update")
            return
        }

        // Preamp: convert dB to linear gain
        let preampLinear = powf(10.0, profile.preampDB / 20.0)

        // Atomic state update + setup swap
        _preampGain = preampLinear
        _filterCount = UInt(filters.count)
        swapSetup(newSetup)
        setEnabled(true)

        // Note: Do NOT reset delay buffers here - the filter naturally adapts to new
        // coefficients using existing state, producing smooth transitions without clicks.
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        guard let profile = _currentProfile, !profile.filters.isEmpty else { return nil }
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            profile.filters, sampleRate: sampleRate,
            profileOptimizedRate: profile.optimizedSampleRate
        )
        return (coefficients, profile.filters.count)
    }

    /// Apply preamp gain before the biquad cascade (RT-safe).
    override func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var preamp = _preampGain
        let sampleCount = frameCount * 2
        vDSP_vsmul(output, 1, &preamp, output, 1, vDSP_Length(sampleCount))
    }
}
