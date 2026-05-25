// FineTuneTests/VoIPCallDetectorTests.swift
import AppKit
import AudioToolbox
import Testing
@testable import FineTune

@Suite("VoIPCallDetector")
@MainActor
struct VoIPCallDetectorTests {
    /// Build an `AudioApp` skeleton sufficient for detector input. Icon is a
    /// blank `NSImage` because the detector never reads it.
    private func makeApp(
        pid: pid_t,
        name: String,
        bundleID: String?
    ) -> AudioApp {
        AudioApp(
            id: pid,
            processObjectIDs: [AudioObjectID(pid)],
            name: name,
            icon: NSImage(),
            bundleID: bundleID
        )
    }

    // MARK: - Bundle-ID matching

    @Test("matches a built-in VoIP bundle ID (case-insensitive)")
    func builtInBundleIDMatch() {
        let detector = VoIPCallDetector()
        let app = makeApp(pid: 100, name: "FaceTime", bundleID: "com.apple.FaceTime")
        detector.update(from: [app])
        #expect(detector.isCallActive)
        #expect(detector.activeCallPIDs == [100])
        #expect(detector.activeCallBundleIDs == ["com.apple.facetime"])
    }

    @Test("ignores an app whose bundle ID is not in the allowlist")
    func unknownBundleIDIgnored() {
        let detector = VoIPCallDetector()
        let app = makeApp(pid: 101, name: "Spotify", bundleID: "com.spotify.client")
        detector.update(from: [app])
        #expect(!detector.isCallActive)
        #expect(detector.activeCallPIDs.isEmpty)
    }

    // MARK: - Name fallback

    @Test("falls back to process name when bundle ID is nil")
    func nameFallbackWhenBundleIDNil() {
        // avconferenced sometimes reports a nil bundle ID via the CoreAudio
        // process-object properties. The detector must still flag it.
        let detector = VoIPCallDetector()
        let app = makeApp(pid: 200, name: "avconferenced", bundleID: nil)
        detector.update(from: [app])
        #expect(detector.isCallActive)
        #expect(detector.activeCallPIDs == [200])
    }

    @Test("name fallback is case-insensitive")
    func nameFallbackCaseInsensitive() {
        let detector = VoIPCallDetector()
        let app = makeApp(pid: 201, name: "AVConferenced", bundleID: nil)
        detector.update(from: [app])
        #expect(detector.isCallActive)
    }

    @Test("non-VoIP daemon with nil bundle ID stays inactive")
    func unknownNameStaysIdle() {
        let detector = VoIPCallDetector()
        let app = makeApp(pid: 202, name: "randomhelperd", bundleID: nil)
        detector.update(from: [app])
        #expect(!detector.isCallActive)
    }

    // MARK: - isVoIPApp predicate

    @Test("isVoIPApp matches both bundle ID and name paths")
    func isVoIPAppCovers() {
        let detector = VoIPCallDetector()
        #expect(detector.isVoIPApp(makeApp(pid: 1, name: "FaceTime", bundleID: "com.apple.FaceTime")))
        #expect(detector.isVoIPApp(makeApp(pid: 2, name: "avconferenced", bundleID: nil)))
        #expect(!detector.isVoIPApp(makeApp(pid: 3, name: "Music", bundleID: "com.apple.Music")))
        #expect(!detector.isVoIPApp(makeApp(pid: 4, name: "Spotify", bundleID: nil)))
    }

    // MARK: - User-configurable allowlist

    @Test("extra bundle IDs from settings extend the allowlist")
    func extraBundleIDsExtend() {
        let detector = VoIPCallDetector(extraBundleIDs: ["org.somefancy.callapp"])
        let app = makeApp(pid: 300, name: "SomeFancyCallApp", bundleID: "org.somefancy.callapp")
        detector.update(from: [app])
        #expect(detector.isCallActive)
    }

    @Test("disabled bundle IDs from settings remove built-ins")
    func disabledBundleIDsRemove() {
        let detector = VoIPCallDetector(
            extraBundleIDs: [],
            disabledBundleIDs: ["com.apple.facetime"]
        )
        let app = makeApp(pid: 400, name: "FaceTime", bundleID: "com.apple.FaceTime")
        detector.update(from: [app])
        // FaceTime is opted out of the allowlist — detector must ignore it.
        // Name fallback also fails because "facetime" isn't in the default
        // process-name list (only daemon names are).
        #expect(!detector.isCallActive)
    }

    @Test("updateBundleIDList re-evaluates current apps")
    func updateBundleIDListReevaluates() {
        let detector = VoIPCallDetector()
        let app = makeApp(pid: 500, name: "ExoticTool", bundleID: "io.example.exotic")

        // Initially not recognised
        detector.update(from: [app])
        #expect(!detector.isCallActive)

        // After the user adds it to the allowlist, it must light up without
        // waiting for the next process-list refresh.
        detector.updateBundleIDList(
            extra: ["io.example.exotic"],
            disabled: [],
            currentApps: [app]
        )
        #expect(detector.isCallActive)
        #expect(detector.activeCallPIDs == [500])
    }

    // MARK: - Callback semantics

    @Test("onCallStateChanged fires only when the PID set changes")
    func callbackOnlyOnChange() {
        let detector = VoIPCallDetector()
        var fireCount = 0
        detector.onCallStateChanged = { _, _ in fireCount += 1 }

        let app = makeApp(pid: 600, name: "FaceTime", bundleID: "com.apple.FaceTime")

        detector.update(from: [app])
        #expect(fireCount == 1)

        // Identical set — must not fire again.
        detector.update(from: [app])
        #expect(fireCount == 1)

        // Removing the call should fire.
        detector.update(from: [])
        #expect(fireCount == 2)
        #expect(!detector.isCallActive)
    }

    @Test("multiple concurrent call apps are all reported")
    func multipleConcurrent() {
        let detector = VoIPCallDetector()
        let facetime = makeApp(pid: 700, name: "FaceTime", bundleID: "com.apple.FaceTime")
        let avc = makeApp(pid: 701, name: "avconferenced", bundleID: nil)
        detector.update(from: [facetime, avc])
        #expect(detector.isCallActive)
        #expect(detector.activeCallPIDs == [700, 701])
    }
}
