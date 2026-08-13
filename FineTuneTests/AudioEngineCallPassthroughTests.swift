// FineTuneTests/AudioEngineCallPassthroughTests.swift
//
// Verifies call passthrough: apps actively capturing audio input (calls) are
// left untapped so macOS's acoustic echo canceller keeps a valid reference
// signal (#113, #404). Reuses RecordingProcessTapController + StubProcessMonitor
// from AudioEngineTapInitialStateTests and the shared device monitor mocks.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let processMonitor: StubProcessMonitor
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
}

private let testPID: pid_t = 54321

@MainActor
private func makeApp(isRunningInput: Bool) -> AudioApp {
    AudioApp(
        id: testPID,
        processObjectIDs: [],
        name: "CallApp",
        icon: NSImage(),
        bundleID: "com.test.callpassthrough",
        isRunningInput: isRunningInput
    )
}

@MainActor
private func makeFixture(activeApp: AudioApp) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-call-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: false
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = 0.75

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [activeApp]

    let box = TapBox()

    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            box.last = tap
            return tap
        },
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        processMonitor: processMonitor,
        device: device,
        lastTap: { box.last }
    )
}

// MARK: - Suite

@Suite("AudioEngine call passthrough — apps capturing input stay untapped (#113, #404)")
@MainActor
struct AudioEngineCallPassthroughTests {

    @Test("No tap is created for an app capturing input while passthrough is enabled (default)")
    func tapCreationSkippedDuringCall() {
        let app = makeApp(isRunningInput: true)
        let fix = makeFixture(activeApp: app)

        fix.engine.setDevice(for: app, deviceUID: fix.device.uid)

        #expect(fix.lastTap() == nil)
    }

    @Test("Disabling call passthrough restores the old always-tap behavior")
    func tapCreatedWhenSettingDisabled() {
        let app = makeApp(isRunningInput: true)
        let fix = makeFixture(activeApp: app)
        var s = fix.settings.appSettings
        s.callPassthroughEnabled = false
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: app, deviceUID: fix.device.uid)

        #expect(fix.lastTap() != nil)
    }

    @Test("Apps not capturing input are tapped as before")
    func nonCallAppStillTapped() {
        let app = makeApp(isRunningInput: false)
        let fix = makeFixture(activeApp: app)

        fix.engine.setDevice(for: app, deviceUID: fix.device.uid)

        #expect(fix.lastTap() != nil)
    }

    @Test("A live tap is released when its app starts capturing input")
    func tapReleasedWhenCallStarts() {
        let idle = makeApp(isRunningInput: false)
        let fix = makeFixture(activeApp: idle)

        fix.engine.setDevice(for: idle, deviceUID: fix.device.uid)
        let tap = fix.lastTap()
        #expect(tap != nil)

        // Call starts: same app reappears with an active input IOProc.
        let onCall = makeApp(isRunningInput: true)
        fix.processMonitor.activeApps = [onCall]
        fix.processMonitor.onAppsChanged?([onCall])

        #expect(tap?.events.contains(.invalidate) == true)
        // No replacement tap while the call runs.
        #expect(fix.lastTap() === tap)
    }

    @Test("The tap is re-provisioned once the app stops capturing input")
    func tapRestoredWhenCallEnds() {
        let idle = makeApp(isRunningInput: false)
        let fix = makeFixture(activeApp: idle)

        fix.engine.setDevice(for: idle, deviceUID: fix.device.uid)
        let callTap = fix.lastTap()

        let onCall = makeApp(isRunningInput: true)
        fix.processMonitor.activeApps = [onCall]
        fix.processMonitor.onAppsChanged?([onCall])
        #expect(callTap?.events.contains(.invalidate) == true)

        // Call ends: input stops, tap comes back on the same routed device.
        fix.processMonitor.activeApps = [idle]
        fix.processMonitor.onAppsChanged?([idle])

        let restored = fix.lastTap()
        #expect(restored != nil)
        #expect(restored !== callTap)
        #expect(restored?.currentDeviceUIDs == [fix.device.uid])
    }

    @Test("Toggling the setting mid-call releases the live tap")
    func reconcileReleasesTapMidCall() {
        let onCall = makeApp(isRunningInput: true)
        let fix = makeFixture(activeApp: onCall)

        // Setting off → tap exists even during the call.
        var s = fix.settings.appSettings
        s.callPassthroughEnabled = false
        fix.settings.updateAppSettings(s)
        fix.engine.setDevice(for: onCall, deviceUID: fix.device.uid)
        let tap = fix.lastTap()
        #expect(tap != nil)

        // User flips it on mid-call.
        s.callPassthroughEnabled = true
        fix.settings.updateAppSettings(s)
        fix.engine.reconcileCallPassthrough()

        #expect(tap?.events.contains(.invalidate) == true)
    }
}
