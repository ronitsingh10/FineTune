// FineTune/Audio/Monitors/VoIPCallDetector.swift
//
// Detects whether a VoIP / conferencing app is currently active so that
// AudioEngine can compensate for macOS's automatic "communication mode" ducking
// of all other audio.
//
// macOS's ducking is applied inside coreaudiod's voice-processing IO mixer
// (kAUVoiceIOOtherAudioDuckingConfiguration). There is no public API on Apple
// Silicon + SIP-enabled systems to bypass it. The pragmatic workaround used
// here is to counter-boost every other tapped process by the same magnitude
// while a call is in progress.
//
// Detection strategy: filter the audio-active process list (already maintained
// by AudioProcessMonitor) by bundle ID against a built-in list of well-known
// VoIP / conferencing apps, plus a user-configurable extension list.

import AppKit
import AudioToolbox
import Foundation
import os

@Observable
@MainActor
final class VoIPCallDetector {
    /// PIDs of audio-active processes recognised as a call.
    private(set) var activeCallPIDs: Set<pid_t> = []

    /// Bundle IDs of the call apps currently active (lower-cased).
    private(set) var activeCallBundleIDs: Set<String> = []

    /// Fired when `activeCallPIDs` actually changes.
    /// Receives `(isAnyCallActive, callPIDs)`.
    var onCallStateChanged: ((Bool, Set<pid_t>) -> Void)?

    /// True when at least one VoIP app is currently using audio.
    var isCallActive: Bool { !activeCallPIDs.isEmpty }

    /// Currently-effective allowlist of VoIP bundle IDs (lower-cased).
    /// Recomputed whenever the user changes settings.
    private(set) var effectiveBundleIDs: Set<String>

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FineTune",
        category: "VoIPCallDetector"
    )

    init(
        extraBundleIDs: Set<String> = [],
        disabledBundleIDs: Set<String> = []
    ) {
        self.effectiveBundleIDs = Self.makeEffectiveBundleIDs(
            extra: extraBundleIDs,
            disabled: disabledBundleIDs
        )
    }

    /// Update the allowlist. Call this when the user edits the bundle-ID list
    /// in settings. Triggers a re-evaluation against the last-seen process list.
    func updateBundleIDList(
        extra: Set<String>,
        disabled: Set<String>,
        currentApps: [AudioApp]
    ) {
        effectiveBundleIDs = Self.makeEffectiveBundleIDs(extra: extra, disabled: disabled)
        update(from: currentApps)
    }

    /// Re-evaluate which apps count as active calls.
    /// Call this from AudioProcessMonitor.onAppsChanged.
    func update(from apps: [AudioApp]) {
        var newCallPIDs: Set<pid_t> = []
        var newCallBundleIDs: Set<String> = []

        for app in apps {
            guard let bundleID = app.bundleID?.lowercased() else { continue }
            if effectiveBundleIDs.contains(bundleID) {
                newCallPIDs.insert(app.id)
                newCallBundleIDs.insert(bundleID)
            }
        }

        guard newCallPIDs != activeCallPIDs else { return }

        let wasActive = !activeCallPIDs.isEmpty
        activeCallPIDs = newCallPIDs
        activeCallBundleIDs = newCallBundleIDs
        let isActive = !newCallPIDs.isEmpty

        if isActive != wasActive {
            logger.info(
                "Call state changed: \(isActive ? "active" : "ended", privacy: .public) — apps: \(newCallBundleIDs.sorted().joined(separator: ", "), privacy: .public)"
            )
        }

        onCallStateChanged?(isActive, newCallPIDs)
    }

    private static func makeEffectiveBundleIDs(
        extra: Set<String>,
        disabled: Set<String>
    ) -> Set<String> {
        let normalizedExtra = Set(extra.map { $0.lowercased() })
        let normalizedDisabled = Set(disabled.map { $0.lowercased() })
        return defaultVoIPBundleIDs
            .subtracting(normalizedDisabled)
            .union(normalizedExtra)
    }

    /// Built-in list of well-known VoIP / video-call / conferencing apps that
    /// drive Apple's voice-processing IO unit and therefore trigger ducking.
    /// All entries are lower-cased; comparisons are case-insensitive.
    static let defaultVoIPBundleIDs: Set<String> = [
        // Apple
        "com.apple.facetime",
        "com.apple.mobilephone",            // Phone (Continuity) on macOS Sequoia+
        "com.apple.telephonyutilities.callservicesd",
        "com.apple.avconferenced",          // Daemon hosting FaceTime/Phone audio

        // Meta
        "net.whatsapp.whatsapp",
        "net.whatsapp.whatsappdesktop",
        "com.facebook.archon",              // Messenger
        "com.facebook.messenger",

        // Microsoft / Google
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.skype.skype",
        "com.skype.skypeforbusiness",
        "com.google.meet",                  // Standalone Meet app
        "com.google.duo",

        // Zoom / Webex / GoTo
        "us.zoom.xos",
        "us.zoom.zoomclips",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webex.meetings",
        "com.logmein.gotomeeting",
        "com.bluejeansnet.bluejeans",

        // Discord / Slack / others
        "com.hnc.discord",
        "com.hnc.discord.ptb",
        "com.hnc.discord.canary",
        "com.tinyspeck.slackmacgap",        // Slack huddles
        "com.signal.signal",
        "com.signal.signal-desktop",
        "org.signal.signal",
        "com.viber.osx",
        "com.linecorp.line.line",
        "com.linecorp.line",
        "com.tencent.xinwechat",            // WeChat
        "com.tencent.wechat",
        "com.jitsi.jitsi-meet",
        "im.riot.app",                       // Element
        "chat.rocket.electron",
    ]
}
