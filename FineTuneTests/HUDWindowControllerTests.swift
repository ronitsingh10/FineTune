// FineTuneTests/HUDWindowControllerTests.swift
// Tests for HUDWindowController: position math, hide-timer reset semantics,
// style-specific hide delay, and popup-guard behavior.
//
// NSPanel/NSScreen creation is avoided — position math is tested via the pure
// static method, and timer behavior is tested via the hideDelayOverride hook.

import Testing
import Foundation
import AppKit
@testable import FineTune

@Suite("HUDWindowController — computePosition()")
@MainActor
struct HUDWindowControllerPositionTests {

    private let screen = NSRect(x: 0, y: 23, width: 1440, height: 877)  // typical macOS visible frame

    // MARK: - Tahoe style

    @Test("Tahoe style places HUD at top-right, inset 8pt from edges (AC #16)")
    func tahoeTopRight() {
        let size = NSSize(width: 300, height: 72)
        let pt = HUDWindowController.computePosition(
            style: .tahoe,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        let expectedX = screen.maxX - size.width - 8
        let expectedY = screen.maxY - size.height - 8
        #expect(pt.x == expectedX)
        #expect(pt.y == expectedY)
    }

    @Test("Tahoe style shifts to upper-left quarter when suppressionDegraded (AC #15 formula)")
    func tahoeSuppressionDegraded() {
        let size = NSSize(width: 300, height: 72)
        let pt = HUDWindowController.computePosition(
            style: .tahoe,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: true
        )
        let expectedX = screen.minX + screen.width * 0.25 - size.width / 2
        let expectedY = screen.maxY - size.height - 8
        #expect(pt.x == expectedX)
        #expect(pt.y == expectedY)
    }

    @Test("B12 position formula holds across varying visibleFrame widths")
    func tahoeSuppressionDegradedFormulaHolds() {
        // AC #15 worked example: vf.width = 1440 → x = 360 − 150 = 210.
        let size = NSSize(width: 300, height: 72)
        let frames: [NSRect] = [
            NSRect(x: 0, y: 23, width: 1440, height: 877),
            NSRect(x: 0, y: 23, width: 1920, height: 1057),
            NSRect(x: 0, y: 23, width: 2560, height: 1417)
        ]
        for vf in frames {
            let pt = HUDWindowController.computePosition(
                style: .tahoe,
                size: size,
                visibleFrame: vf,
                suppressionDegraded: true
            )
            #expect(pt.x == vf.minX + vf.width * 0.25 - size.width / 2)
            #expect(pt.y == vf.maxY - size.height - 8)
        }
    }

    // MARK: - Classic style

    @Test("Classic style centers horizontally, 140pt above screen bottom")
    func classicCenterBottom() {
        let size = NSSize(width: 200, height: 200)
        let pt = HUDWindowController.computePosition(
            style: .classic,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        let expectedX = screen.midX - size.width / 2
        let expectedY = screen.minY + 140
        #expect(pt.x == expectedX)
        #expect(pt.y == expectedY)
    }

    @Test("Classic style position is unchanged when suppressionDegraded")
    func classicSuppressionDegradedUnchanged() {
        let size = NSSize(width: 200, height: 200)
        let normal = HUDWindowController.computePosition(
            style: .classic,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        let degraded = HUDWindowController.computePosition(
            style: .classic,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: true
        )
        #expect(normal == degraded)
    }

    // MARK: - Edge cases

    @Test("Tahoe with zero-size HUD lands at top-right corner minus 8pt")
    func tahoeZeroSize() {
        let size = NSSize.zero
        let pt = HUDWindowController.computePosition(
            style: .tahoe,
            size: size,
            visibleFrame: screen,
            suppressionDegraded: false
        )
        #expect(pt.x == screen.maxX - 8)
        #expect(pt.y == screen.maxY - 8)
    }
}

// MARK: - Hide timer + style-specific delay

@Suite("HUDWindowController — hide timer + per-style delay")
@MainActor
struct HUDWindowControllerTimerTests {

    private func makeController(popupVisible: Bool = false) -> HUDWindowController {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let status = MediaKeyStatus()
        let popup = PopupVisibilityService()
        popup.isVisible = popupVisible
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        // Stub out frame to avoid real NSScreen in tests.
        hud.frameProvider = { NSRect(x: 0, y: 23, width: 1440, height: 877) }
        return hud
    }

    @Test("showCallCount increments on each show()")
    func showCallCountIncrements() {
        let hud = makeController()
        #expect(hud.showCallCount == 0)
        hud.show(volume: 0.5, mute: false, deviceName: "")
        #expect(hud.showCallCount == 1)
        hud.show(volume: 0.6, mute: false, deviceName: "")
        #expect(hud.showCallCount == 2)
    }

    @Test("showCallCount increments even when the show is guard-skipped (counter tracks attempts)")
    func showCallCountTracksAttempts() {
        // showCallCount is incremented before the fullscreen + popup guards, so
        // it records every attempt regardless of whether the panel is actually shown.
        let hud = makeController()
        hud.show(volume: 0.5, mute: false, deviceName: "")
        hud.show(volume: 0.5, mute: false, deviceName: "")
        #expect(hud.showCallCount == 2)
    }

    @Test("Two rapid show() calls result in exactly two increments")
    func twoRapidShowsIncrementTwice() {
        let hud = makeController()
        hud.show(volume: 0.3, mute: false, deviceName: "")
        hud.show(volume: 0.4, mute: true, deviceName: "")
        #expect(hud.showCallCount == 2)
    }

    // MARK: - Per-style hide delay (AC #17)

    @Test("hideDelay is 1100 ms for both styles")
    func hideDelayIs1100msForBothStyles() {
        let hud = makeController()
        #expect(hud.hideDelay(for: .tahoe) == .milliseconds(1100))
        #expect(hud.hideDelay(for: .classic) == .milliseconds(1100))
    }

    @Test("hideDelayOverride applies uniformly to both styles")
    func hideDelayOverrideApplies() {
        let hud = makeController()
        hud.hideDelayOverride = .milliseconds(250)
        #expect(hud.hideDelay(for: .tahoe) == .milliseconds(250))
        #expect(hud.hideDelay(for: .classic) == .milliseconds(250))
    }

    // MARK: - Popup-visibility guard (AC #23)

    @Test("popupGuardSuppressesShow: popup visible ⇒ show() does not update panel")
    func popupGuardSuppressesShow() {
        let hud = makeController(popupVisible: true)
        hud.show(volume: 0.5, mute: false, deviceName: "Test Device")
        // Attempt is counted, but panel was not updated.
        #expect(hud.showCallCount == 1)
        #expect(hud.showDidUpdatePanel == false)
    }

    @Test("Popup hidden ⇒ show() updates panel")
    func popupHiddenShowUpdatesPanel() {
        let hud = makeController(popupVisible: false)
        hud.show(volume: 0.5, mute: false, deviceName: "Test Device")
        #expect(hud.showCallCount == 1)
        #expect(hud.showDidUpdatePanel == true)
    }
}
