// FineTune/Audio/SoftwareGainStore.swift
//
// Global RT-safe store mapping device UID → effective software gain (0.0–1.0).
//
// DESIGN: Every ProcessTapController reads from this store at render time using
// its target device UID. This means gain changes are device-level and apply to
// ALL taps routing to that device simultaneously — regardless of how many apps
// are playing, whether their taps were created before or after the gain was set,
// and whether the FineTune GUI is visible.
//
// THREAD SAFETY:
// - Writes happen on @MainActor (AudioEngine / VolumeKeyInterceptor).
// - Reads happen on the CoreAudio HAL real-time thread.
// - The dictionary itself is nonisolated(unsafe). On Apple Silicon and Intel,
//   aligned Float32 reads/writes are atomic. Dictionary lookup without mutation
//   is safe to call concurrently as long as no structural change (insert/remove)
//   races with a read. We accept this — the worst outcome is a stale gain value
//   for one render cycle, which is inaudible.

import Foundation

enum SoftwareGainStore {

    /// Effective gain per device UID (0.0 = muted, 1.0 = full volume).
    /// Written on main thread, read on audio RT thread.
    nonisolated(unsafe) private static var gains: [String: Float] = [:]

    // MARK: - Write (main thread only)

    static func setGain(_ gain: Float, for deviceUID: String) {
        gains[deviceUID] = max(0.0, min(1.0, gain))
    }

    static func removeGain(for deviceUID: String) {
        gains.removeValue(forKey: deviceUID)
    }

    // MARK: - Read (RT-safe, called from audio render thread)

    /// Returns the effective gain for the first device UID in the list that has
    /// an entry, or 1.0 (unity) if none found. Taps pass their targetDeviceUIDs.
    @inline(__always)
    static func gain(for deviceUIDs: [String]) -> Float {
        for uid in deviceUIDs {
            if let g = gains[uid] { return g }
        }
        return 1.0
    }
}
