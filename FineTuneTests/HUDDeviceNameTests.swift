// FineTuneTests/HUDDeviceNameTests.swift
// AC #13, #18 coverage: device-name font exposure, Classic percentage-label
// structural assertion, and smoke test that show(volume:mute:deviceName:)
// with a long device name doesn't crash preview construction.

import Testing
import SwiftUI
import AppKit
@testable import FineTune

@Suite("TahoeStyleHUD — device-name font (AC #13)")
@MainActor
struct TahoeStyleHUDNameFontTests {

    @Test("nameFont equals the system 13pt semibold font (rowNameBold token)")
    func nameFontIsRowNameBold() {
        #expect(TahoeStyleHUD.nameFont == .system(size: 13, weight: .semibold))
        #expect(TahoeStyleHUD.nameFont == DesignTokens.Typography.rowNameBold)
    }
}

@Suite("ClassicStyleHUD — no percentage label (AC #18)")
struct ClassicStyleHUDStructureTests {

    @Test("hasPercentageLabel is false (volumeHUD parity)")
    func classicHasNoPercentageLabel() {
        #expect(ClassicStyleHUD.hasPercentageLabel == false)
    }
}

@Suite("HUDWindowController.show(volume:mute:deviceName:) — smoke + overflow")
@MainActor
struct HUDDeviceNameSmokeTests {

    private func makeController(popupVisible: Bool = false) -> HUDWindowController {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let status = MediaKeyStatus()
        let popup = PopupVisibilityService()
        popup.isVisible = popupVisible
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        hud.frameProvider = { NSRect(x: 0, y: 23, width: 1440, height: 877) }
        hud.foregroundAppFullscreenProvider = { false }
        return hud
    }

    @Test("show() with a short device name completes without crashing")
    func shortNameSmoke() {
        let hud = makeController()
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "AirPods Pro")
        #expect(hud.showCallCount == 1)
    }

    @Test("show() with an empty device name completes without crashing")
    func emptyNameSmoke() {
        let hud = makeController()
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
        #expect(hud.showCallCount == 1)
    }

    @Test("show() with a 60-char device name completes without crashing (overflow path)")
    func longNameSmoke() {
        let hud = makeController()
        let longName = "Ronit's MacBook Pro Speakers (Built-in Audio Output)"
        hud.show(sliderFraction: 0.75, mute: false, deviceName: longName)
        #expect(hud.showCallCount == 1)
    }

    @Test("TahoeStyleHUD constructs without error for a 60-char device name")
    func longNamePreviewConstruction() {
        let longName = "Ronit's MacBook Pro Speakers (Built-in Audio Output)"
        // Construction-only smoke; rendering is covered by xcode-cli preview.
        _ = TahoeStyleHUD(sliderFraction: 0.75, mute: false, deviceName: longName)
    }
}
