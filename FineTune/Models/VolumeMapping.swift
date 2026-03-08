// FineTune/Models/VolumeMapping.swift
import Foundation

/// Utility for converting between slider position and audio gain.
/// Linear mapping: 50% slider = 100% gain (unity), visual consistency over audio precision.
enum VolumeMapping {
    /// Convert slider position (0-1) to linear gain
    /// Linear mapping: 50% slider = unity gain (1.0)
    /// - Parameters:
    ///   - slider: Normalized slider position 0.0 to 1.0
    ///   - maxBoost: Maximum volume multiplier (e.g., 2.0 = 200%, 4.0 = 400%)
    /// - Returns: Linear gain multiplier (0 to maxBoost)
    static func sliderToGain(_ slider: Double, maxBoost: Float = 2.0) -> Float {
        if slider <= 0.5 {
            // 0-50% slider → 0-100% gain (linear attenuation)
            return Float(slider * 2)
        } else {
            // 50-100% slider → 100%-maxBoost (linear boost)
            let t = (slider - 0.5) / 0.5
            return 1.0 + Float(t) * (maxBoost - 1.0)
        }
    }

    /// Convert linear gain to slider position (0-1)
    /// - Parameters:
    ///   - gain: Linear gain multiplier
    ///   - maxBoost: Maximum volume multiplier (e.g., 2.0 = 200%, 4.0 = 400%)
    /// - Returns: Normalized slider position 0.0 to 1.0
    static func gainToSlider(_ gain: Float, maxBoost: Float = 2.0) -> Double {
        if gain <= 1.0 {
            // 0-100% gain → 0-50% slider
            return Double(gain * 0.5)
        } else {
            // 100%-maxBoost → 50-100% slider
            let t = (gain - 1.0) / (maxBoost - 1.0)
            return 0.5 + Double(t) * 0.5
        }
    }
}
