// FineTune/Audio/Engine/PanMath.swift
import Foundation

/// Per-app stereo pan math. Pure, allocation-free, RT-safe.
///
/// Pan is a single value in [-1, 1]: -1 = full left, 0 = center (passthrough), 1 = full right.
///
/// A plain balance control would throw away half of a stereo source when panned hard
/// (music panned full left would lose its right channel). Instead, as the pan moves
/// away from center the source is progressively folded to mono, then the far side is
/// attenuated linearly. At ±1 the whole program sits in one ear, nothing is lost:
///
///     pan  0.0  →  L = l,            R = r              (bit-exact passthrough)
///     pan -1.0  →  L = (l + r) / 2,  R = 0
///     pan +1.0  →  L = 0,            R = (l + r) / 2
///
/// This is what lets two apps share one pair of headphones, one per ear.
enum PanMath {
    /// Below this distance the ramp snaps to its target, so a pan returned to center
    /// lands on exactly 0 and the passthrough fast path re-engages.
    static let snapThreshold: Float = 1e-4

    @inline(__always)
    static func clamp(_ pan: Float) -> Float {
        guard pan.isFinite else { return 0 }
        return min(max(pan, -1), 1)
    }

    /// Advances a one-pole ramp toward `target`, snapping when close.
    @inline(__always)
    static func ramp(current: inout Float, target: Float, coefficient: Float) {
        let diff = target - current
        if abs(diff) < snapThreshold {
            current = target
        } else {
            current += diff * coefficient
        }
    }

    /// Gain applied to the left and right outputs for a given pan.
    @inline(__always)
    static func gains(pan: Float) -> (left: Float, right: Float) {
        (min(1, 1 - pan), min(1, 1 + pan))
    }

    /// Pans one stereo frame.
    @inline(__always)
    static func applyStereo(left: Float, right: Float, pan: Float) -> (left: Float, right: Float) {
        let width = abs(pan)
        let mid = 0.5 * (left + right)
        let foldedLeft = left + (mid - left) * width
        let foldedRight = right + (mid - right) * width
        let (gainLeft, gainRight) = gains(pan: pan)
        return (foldedLeft * gainLeft, foldedRight * gainRight)
    }

    /// Pans one mono sample into a stereo pair.
    @inline(__always)
    static func applyMono(_ sample: Float, pan: Float) -> (left: Float, right: Float) {
        let (gainLeft, gainRight) = gains(pan: pan)
        return (sample * gainLeft, sample * gainRight)
    }
}
