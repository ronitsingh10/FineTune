// FineTune/Models/StereoBalance.swift
import Foundation

/// macOS-style stereo balance helpers.
///
/// Convention matches System Settings / `VirtualMainBalance`:
/// - `0.0` = full left
/// - `0.5` = center
/// - `1.0` = full right
///
/// Channel gains attenuate the quieter side only (never boost above 1.0).
enum StereoBalance {
    static let center: Float = 0.5

    static func clamp(_ balance: Float) -> Float {
        guard balance.isFinite else { return center }
        return Swift.max(0.0, Swift.min(1.0, balance))
    }

    /// Left/right linear gains for a balance value.
    /// - `0.5 → (1, 1)`
    /// - `0.0 → (1, 0)`
    /// - `1.0 → (0, 1)`
    /// - `0.25 → (1, 0.5)` (right attenuated)
    /// - `0.75 → (0.5, 1)` (left attenuated)
    static func channelGains(for balance: Float) -> (left: Float, right: Float) {
        let b = clamp(balance)
        if b <= center {
            // Left half: left stays full, right fades 1→0 as b goes 0.5→0
            let right = b * 2.0
            return (1.0, right)
        } else {
            // Right half: right stays full, left fades 1→0 as b goes 0.5→1
            let left = (1.0 - b) * 2.0
            return (left, 1.0)
        }
    }

    /// Inverse of channel-volume balance: louder side is the reference.
    static func fromChannelVolumes(left: Float, right: Float) -> Float {
        let l = Swift.max(0.0, left)
        let r = Swift.max(0.0, right)
        let maxVol = Swift.max(l, r)
        guard maxVol > 0 else { return center }
        // Normalize so louder channel = 1
        let nl = l / maxVol
        let nr = r / maxVol
        if abs(nl - nr) < 1e-5 {
            return center
        }
        if nl >= nr {
            // Right is quieter → balance is left of center: rightGain = balance * 2
            return nr / 2.0
        } else {
            // Left is quieter → balance is right of center: leftGain = (1 - balance) * 2
            return 1.0 - (nl / 2.0)
        }
    }
}
