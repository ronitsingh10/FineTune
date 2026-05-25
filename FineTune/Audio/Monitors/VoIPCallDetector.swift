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

    /// Currently-effective allowlist of VoIP process executable names (lower-cased).
    /// Used as a fallback when the audio-process object reports a nil bundle ID —
    /// system daemons like `avconferenced` and `callservicesd` rarely have a bundle ID.
    private(set) var effectiveProcessNames: Set<String>

    init(
        extraBundleIDs: Set<String> = [],
        disabledBundleIDs: Set<String> = []
    ) {
        self.effectiveBundleIDs = Self.makeEffectiveBundleIDs(
            extra: extraBundleIDs,
            disabled: disabledBundleIDs
        )
        self.effectiveProcessNames = Self.defaultVoIPProcessNames
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

    /// Returns true if the given app is in our VoIP allowlist (by bundle ID or
    /// process name). Used by AudioEngine to skip tap creation for call apps —
    /// tapping them would route call audio through our aggregate device, which
    /// macOS's voice-processing mixer then treats as "other audio" and ducks,
    /// silencing the actual call.
    func isVoIPApp(_ app: AudioApp) -> Bool {
        let bundleID = app.bundleID?.lowercased()
        let processName = app.name.lowercased()
        let bundleMatch = bundleID.map { effectiveBundleIDs.contains($0) } ?? false
        let nameMatch = effectiveProcessNames.contains(processName)
        return bundleMatch || nameMatch
    }

    /// Re-evaluate which apps count as active calls.
    /// Call this from AudioProcessMonitor.onAppsChanged.
    ///
    /// Matches on bundle ID first, falls back to process executable name.
    /// The fallback is essential for `avconferenced` and similar XPC daemons
    /// whose `kAudioProcessPropertyBundleID` is nil even though they're the
    /// actual host of FaceTime/Phone call audio.
    func update(from apps: [AudioApp]) {
        var newCallPIDs: Set<pid_t> = []
        var newCallBundleIDs: Set<String> = []

        // Diagnostic dump of every audio-active app so missed-match cases
        // (e.g. a new VoIP daemon with a name we don't recognise) can be
        // investigated by raising the log level via the Console.app filter.
        // `.debug` keeps it out of the default unified-log stream.
        let snapshot = apps.map { "\($0.name)|\($0.bundleID ?? "nil")" }
            .joined(separator: ", ")
        logger.debug("Scanning \(apps.count, privacy: .public) audio-active processes: \(snapshot, privacy: .public)")

        for app in apps {
            let bundleID = app.bundleID?.lowercased()
            let processName = app.name.lowercased()

            let bundleMatch = bundleID.map { effectiveBundleIDs.contains($0) } ?? false
            let nameMatch = effectiveProcessNames.contains(processName)

            if bundleMatch || nameMatch {
                newCallPIDs.insert(app.id)
                newCallBundleIDs.insert(bundleID ?? processName)
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

    /// Built-in list of well-known VoIP daemon / XPC executable names whose
    /// `kAudioProcessPropertyBundleID` is typically nil. These are matched on
    /// `AudioApp.name` (lower-cased) as a fallback when bundle ID lookup fails.
    ///
    /// Most importantly: `avconferenced` is the actual audio host for FaceTime
    /// and Phone calls on macOS — without name matching, the detector would
    /// boost it as "other audio" and the call itself would clip in our limiter.
    static let defaultVoIPProcessNames: Set<String> = [
        "avconferenced",
        "callservicesd",
        "telephonyutilities",
    ]

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
