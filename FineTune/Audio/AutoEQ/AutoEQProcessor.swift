// FineTune/Audio/AutoEQ/AutoEQProcessor.swift
import Foundation
import Accelerate

/// RT-safe parametric EQ processor for AutoEQ headphone correction.
///
/// Subclass of `SVFProcessor` — inherits delay buffer management, atomic setup swaps,
/// stereo SVF processing, and NaN safety. This class adds AutoEQ-specific profile
/// management and a preamp gain stage applied before the SVF cascade.
final class AutoEQProcessor: SVFProcessor, @unchecked Sendable {

    /// Currently applied profile (needed for sample rate recalculation)
    private var _currentProfile: AutoEQProfile?

    /// Read-only access to current profile
    var currentProfile: AutoEQProfile? { _currentProfile }

    /// Whether to apply the profile's preamp (false = bypass preamp, rely on limiter)
    private var _preampEnabled: Bool = true

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

        let validated = profile?.validated()
        guard let validated, !validated.filters.isEmpty else {
            // Disable: atomic writes
            setEnabled(false)
            _filterCount = 0
            _preampGain = 1.0
            swapSetup(nil)
            logger.info("AutoEQ disabled — \(profile == nil ? "nil profile" : "no valid filters after validation")")
            return
        }

        let filters = validated.filters
        let coefficients = SVFMath.coefficientsForAutoEQFilters(
            filters, sampleRate: sampleRate,
            profileOptimizedRate: validated.optimizedSampleRate
        )

        // Preamp: convert dB to linear gain (bypassed when preamp disabled — limiter handles peaks)
        let preampLinear = _preampEnabled ? powf(10.0, validated.preampDB / 20.0) : 1.0

        // Atomic state update + setup swap
        _preampGain = preampLinear
        _filterCount = UInt(filters.count)
        swapSetup(coefficients)
        setEnabled(true)

        let preampStatus = self._preampEnabled ? "active" : "bypassed"
        logger.info("AutoEQ applied: \"\(validated.name)\" — \(filters.count) filters, preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus)), gain \(preampLinear, format: .fixed(precision: 3))x, rate \(self.sampleRate, format: .fixed(precision: 0)) Hz")

        // Note: Do NOT reset delay buffers here - the filter naturally adapts to new
        // coefficients using existing state, producing smooth transitions without clicks.
    }

    // MARK: - Preamp Mode

    /// Toggle profile preamp on/off. When off, relies on downstream limiter for peak control.
    func setPreampEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled != _preampEnabled else { return }
        _preampEnabled = enabled
        logger.info("AutoEQ preamp \(enabled ? "enabled" : "bypassed (limiter-only)")")
        // Re-apply current profile to update the preamp gain atomically
        if let profile = _currentProfile {
            updateProfile(profile)
        }
    }

    // MARK: - SVFProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        guard let profile = _currentProfile?.validated(), !profile.filters.isEmpty else { return nil }
        let coefficients = SVFMath.coefficientsForAutoEQFilters(
            profile.filters, sampleRate: sampleRate,
            profileOptimizedRate: profile.optimizedSampleRate
        )
        return (coefficients, profile.filters.count)
    }

    /// Apply preamp gain before the SVF cascade (RT-safe).
    override func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var preamp = _preampGain
        let sampleCount = frameCount * 2
        vDSP_vsmul(output, 1, &preamp, output, 1, vDSP_Length(sampleCount))
    }
}
