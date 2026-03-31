// FineTune/Models/VolumeMapping.swift
import Foundation

/// Utility for converting between slider position (0-1) and audio gain (0-1).
/// Square-law (x²) curve: more control at low volumes for per-app mixing.
/// Percentage displays slider position, not raw gain.
/// Boost is handled separately per-app, not in this mapping.
enum VolumeMapping {
    private static let sliderMinDecibels: Double = -30.0
    private static let sliderMaxDecibels: Double = 0.0

    /// Convert slider position to gain using square-law curve.
    static func sliderToGain(_ slider: Double, logScale: Bool) -> Float {
        if slider <= 0 {
            return 0
        } else if logScale {
            let decibels = slider * (sliderMaxDecibels - sliderMinDecibels) + sliderMinDecibels
            return decibelsToGain(decibels)
        } else {
            let t = min(slider, 1.0)
            return Float(t * t)
        }
    }

    /// Convert gain to slider position using inverse square-law (sqrt).
    static func gainToSlider(_ gain: Float, logScale: Bool) -> Double {
        if gain <= 0 {
            return 0
        } else if logScale {
            let decibels = gainToDecibels(gain)
            return (decibels - sliderMinDecibels) / (sliderMaxDecibels - sliderMinDecibels)
        } else {
            return Double(sqrt(min(gain, 1.0)))
        }
    }

    static func decibelsToGain(_ decibels: Double) -> Float {
        return Float(pow(10.0, decibels / 20.0))
    }

    static func gainToDecibels(_ gain: Float) -> Double {
        return log10(Double(gain)) * 20.0
    }
}
