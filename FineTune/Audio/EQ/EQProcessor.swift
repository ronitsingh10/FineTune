// FineTune/Audio/EQ/EQProcessor.swift
import Foundation
import Accelerate

/// RT-safe 10-band graphic EQ processor using vDSP_biquad.
///
/// Subclass of `BiquadProcessor` — inherits delay buffer management, atomic setup swaps,
/// stereo biquad processing, and NaN safety. This class adds EQ-specific settings
/// management and preamp attenuation computation.
final class EQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Currently applied EQ settings (needed for sample rate recalculation)
    private var _currentSettings: EQSettings?

    /// Read-only access to current settings
    var currentSettings: EQSettings? { _currentSettings }

    /// Pre-EQ attenuation to prevent post-EQ clipping when bands are boosted.
    /// Computed as: pow(10, -maxBoostDB / 20) when any band has positive gain.
    /// Audio callback reads this atomically; main thread writes in updateSettings().
    private nonisolated(unsafe) var _preampAttenuation: Float = 1.0

    /// Pre-EQ gain reduction to prevent clipping (RT-safe read)
    var preampAttenuation: Float { _preampAttenuation }

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: EQSettings.bandCount,
            category: "EQProcessor",
            initiallyEnabled: true
        )
        // Initialize with flat EQ
        updateSettings(EQSettings.flat)
    }

    // MARK: - Settings Update

    /// Update EQ settings (call from main thread).
    func updateSettings(_ settings: EQSettings) {
        setEnabled(settings.isEnabled)
        _currentSettings = settings

        // Compute pre-EQ attenuation to prevent post-EQ clipping
        let maxBoostDB = settings.clampedGains.max() ?? 0
        _preampAttenuation = maxBoostDB > 0 ? pow(10.0, -maxBoostDB / 20.0) : 1.0

        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )

        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }

        swapSetup(newSetup)

        // Note: Do NOT reset delay buffers here - the filter naturally adapts to new
        // coefficients using existing state, producing smooth transitions without clicks.
        // Delay buffers are only reset on init and sample rate changes.
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        guard let settings = _currentSettings else { return nil }
        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )
        return (coefficients, EQSettings.bandCount)
    }
}
