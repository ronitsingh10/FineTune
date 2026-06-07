// FineTuneTests/MediaKeyTapDisabledTests.swift
// Tests for MediaKeyMonitor tap-disabled watchdog (B11):
//   - Single disable within 5s window → isOffline stays false (re-enabled)
//   - Double disable within 5s window → isOffline = true

import Testing
import Foundation
import AudioToolbox
import CoreGraphics
@testable import FineTune

@Suite("MediaKeyMonitor — tap-disabled watchdog (B11)")
@MainActor
struct MediaKeyTapDisabledTests {

    private func makeMonitor(
        isTrusted: Bool = true
    ) -> (MediaKeyMonitor, MediaKeyStatus, MockAccessibilityTrustProviding) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        var appSettings = settings.appSettings
        appSettings.mediaKeyControlEnabled = true
        settings.updateAppSettings(appSettings)

        let deviceMonitor = MockAudioDeviceMonitor()
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: mockVolume,
            startMonitorsAutomatically: false
        )

        let status = MediaKeyStatus()
        let popup = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        hud.frameProvider = { NSRect(x: 0, y: 0, width: 1440, height: 900) }
        hud.foregroundAppFullscreenProvider = { false }
        let accessibility = MockAccessibilityTrustProviding(isTrusted: isTrusted)
        let monitor = MediaKeyMonitor(
            decoder: StubMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibility,
            hudController: hud,
            popupVisibility: popup,
            mediaKeyStatus: status
        )
        return (monitor, status, accessibility)
    }

    @Test("Single tap-disabled event leaves isOffline false (watchdog opens, one re-enable)")
    func singleDisableDoesNotGoOffline() async {
        let (monitor, status, _) = makeMonitor()

        // First disable — should attempt re-enable and open watchdog window.
        // No real tap installed, so CGEvent.tapEnable is a no-op, but watchdogOpen
        // must be set and isOffline must remain false.
        monitor.handleTapDisabled()

        #expect(status.isOffline == false)
        #expect(monitor.watchdogOpen == true)
    }

    @Test("Double tap-disabled within watchdog window sets isOffline to true")
    func doubleDisableWithinWindowGoesOffline() async {
        let (monitor, status, _) = makeMonitor()

        // First disable opens watchdog.
        monitor.handleTapDisabled()
        #expect(status.isOffline == false)
        #expect(monitor.watchdogOpen == true)

        // Second disable within the window → marks offline.
        monitor.handleTapDisabled()
        #expect(status.isOffline == true)
        #expect(monitor.watchdogOpen == false)
    }

    @Test("isOffline is false before any tap events")
    func initialStateOfflineFalse() {
        let (_, status, _) = makeMonitor()
        #expect(status.isOffline == false)
    }

    @Test("After double disable, watchdogOpen is reset to false")
    func watchdogResetAfterDoubleDisable() async {
        let (monitor, _, _) = makeMonitor()
        monitor.handleTapDisabled()
        monitor.handleTapDisabled()
        #expect(monitor.watchdogOpen == false)
    }

    @Test("tap-disabled while AX is no longer trusted takes the revocation branch")
    func revocationBranchWhenNotTrusted() async {
        let (monitor, status, accessibility) = makeMonitor(isTrusted: false)

        monitor.handleTapDisabled()

        // Revocation path: does NOT mark offline (that's reserved for kernel
        // stalls), does NOT arm the watchdog; instead tears down and calls
        // accessibility.refresh() so the UI surfaces the permission card.
        #expect(status.isOffline == false)
        #expect(monitor.watchdogOpen == false)
        #expect(accessibility.refreshCallCount == 1)
    }

    @Test("revocation branch does not arm the watchdog even on repeated calls")
    func revocationIsIdempotent() async {
        let (monitor, status, accessibility) = makeMonitor(isTrusted: false)

        monitor.handleTapDisabled()
        monitor.handleTapDisabled()

        #expect(status.isOffline == false)
        #expect(monitor.watchdogOpen == false)
        #expect(accessibility.refreshCallCount == 2)
    }
}
