// FineTune/Audio/Feedback/VolumeFeedbackPlayer.swift
import AppKit
import os

/// Decision logic for the volume-change feedback pop, separated from playback for testing.
enum VolumeFeedback {
    /// Shift alone inverts the system preference; Option+Shift follows it unchanged.
    static func shouldPlay(prefOn: Bool, shiftHeld: Bool, optionHeld: Bool) -> Bool {
        if shiftHeld && !optionHeld { return !prefOn }
        return prefOn
    }

    /// The pop bypasses FineTune's taps. Software-tier devices attenuate inside the taps,
    /// so the pop self-scales with the same mapping; hardware/DDC attenuate in the device.
    static func gain(tier: VolumeControlTier, sliderFraction: Double) -> Float {
        switch tier {
        case .hardware, .ddc:
            return 1.0
        case .software:
            return VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: .software)
        }
    }
}

/// Plays the macOS volume-feedback pop on the default output device,
/// honoring the system "Play feedback when volume is changed" preference.
@MainActor
final class VolumeFeedbackPlayer {
    /// Min interval between pops, so key-repeat and HUD-drag can't machine-gun the sound.
    static let cooldown: TimeInterval = 0.15

    private static nonisolated let systemSoundPath =
        "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    // By path, not soundNamed: — cached soundNamed instances stop honoring the
    // playback device after long process uptime (Apple #12506583).
    private static nonisolated let fallbackSoundPath = "/System/Library/Sounds/Tink.aiff"

    private nonisolated let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "VolumeFeedbackPlayer")

    private var lastPlay: TimeInterval = -.infinity

    /// `play()` blocks ~10–40 ms — too long for the main thread at key-repeat and
    /// HUD-drag rates, so playback happens on a dedicated serial queue.
    /// `sound`/`loadAttempted` are confined to `queue` — that is the contract.
    private nonisolated let queue = DispatchQueue(label: "com.finetuneapp.FineTune.volume-feedback", qos: .userInitiated)
    private nonisolated(unsafe) var sound: NSSound?
    private nonisolated(unsafe) var loadAttempted = false

    func requestFeedback(gain: Float, shiftHeld: Bool = false, optionHeld: Bool = false) {
        guard VolumeFeedback.shouldPlay(
            prefOn: Self.systemPreferenceEnabled(),
            shiftHeld: shiftHeld,
            optionHeld: optionHeld
        ) else { return }
        guard passesCooldown(at: ProcessInfo.processInfo.systemUptime) else { return }
        queue.async { [self] in playOnQueue(gain: gain) }
    }

    /// Leading-edge gate. Visible for tests.
    func passesCooldown(at t: TimeInterval) -> Bool {
        guard t - lastPlay >= Self.cooldown else { return false }
        lastPlay = t
        return true
    }

    /// Live read of the System Settings toggle. Absent key = off.
    static func systemPreferenceEnabled() -> Bool {
        CFPreferencesGetAppBooleanValue(
            "com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication, nil
        )
    }

    private nonisolated func playOnQueue(gain: Float) {
        dispatchPrecondition(condition: .onQueue(queue))
        if !loadAttempted {
            loadAttempted = true
            sound = NSSound(contentsOfFile: Self.systemSoundPath, byReference: true)
                ?? NSSound(contentsOfFile: Self.fallbackSoundPath, byReference: true)
            if sound == nil {
                logger.info("No feedback sound available on this system; volume feedback disabled")
            }
        }
        guard let sound else { return }
        sound.stop()  // rewinds to 0; play() while playing would return false
        sound.volume = gain
        if !sound.play() {
            logger.debug("Feedback play() returned false — dropped")
        }
    }
}
