// FineTuneTests/MediaKeyMonitorHandlerTests.swift
// Tests for MediaKeyMonitor.handleCore() — the volume/mute logic decoupled from
// real CGEventTap, AudioEngine, and DeviceVolumeMonitor.
//
// Strategy: call handleCore directly, injecting closure stubs. No real CoreAudio is touched.

import Testing
import Foundation
import AudioToolbox
import CoreGraphics
@testable import FineTune

// MARK: - Stub decoder and HUD controller helpers

/// Stub decoder that always returns a pre-configured event.
final class StubMediaKeyDecoder: MediaKeyEventDecoding, @unchecked Sendable {
    var nextEvent: MediaKeyEvent?
    func decode(data1: Int) -> MediaKeyEvent? { nextEvent }
}

// MARK: - Test suite

@Suite("MediaKeyMonitor — handleCore() volume/mute logic")
@MainActor
struct MediaKeyMonitorHandlerTests {

    // MARK: Helpers

    private func makeMonitor(
        hudController: HUDWindowController? = nil,
        popupVisible: Bool = false
    ) -> (monitor: MediaKeyMonitor, hud: HUDWindowController, popup: PopupVisibilityService, settingsManager: SettingsManager) {
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

        let mediaKeyStatus = MediaKeyStatus()
        let popup = PopupVisibilityService()
        popup.isVisible = popupVisible
        let hud = hudController ?? HUDWindowController(settingsManager: settings, mediaKeyStatus: mediaKeyStatus, popupVisibility: popup)
        // Replace frameProvider to avoid NSScreen access in unit tests.
        hud.frameProvider = { NSRect(x: 0, y: 0, width: 1440, height: 900) }

        let monitor = MediaKeyMonitor(
            decoder: StubMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: MockAccessibilityTrustProviding(isTrusted: true),
            hudController: hud,
            popupVisibility: popup,
            mediaKeyStatus: mediaKeyStatus
        )
        return (monitor, hud, popup, settings)
    }

    // MARK: - Volume step arithmetic

    @Test("volumeUp on software tier steps in slider domain (x² taper)")
    func volumeUpStep() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        let nextSlider = sqrt(Double(0.5)) + 1.0 / 16.0
        let expected = Float(nextSlider * nextSlider)
        #expect(abs((writtenVolume ?? 0) - expected) < 1e-5)
    }

    @Test("volumeDown on software tier steps in slider domain (x² taper)")
    func volumeDownStep() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        let nextSlider = sqrt(Double(0.5)) - 1.0 / 16.0
        let expected = Float(nextSlider * nextSlider)
        #expect(abs((writtenVolume ?? 0) - expected) < 1e-5)
    }

    @Test("volumeUp clamps at 1.0 when current is 0.9375 or higher")
    func volumeUpClamp() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 1.0,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        #expect(writtenVolume == 1.0)
    }

    @Test("volumeDown clamps at 0.0 when current is already 0")
    func volumeDownClamp() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.0,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        #expect(writtenVolume == 0.0)
    }

    // MARK: - Repeat handling (AC #6, #7, #8, #10)

    @Test("volumeUp(isRepeat: true) from 0.5 steps volume to 0.5625 (AC #7 companion)")
    func volumeUpRepeatStepsVolume() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: true),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        let expected: Float = 0.5 + 1.0 / 16.0
        #expect(writtenVolume == expected)
    }

    @Test("volumeDown(isRepeat: true) from 0.5 writes 0.4375 (AC #6)")
    func volumeDownRepeatStepsVolume() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: true),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, _ in }
        )
        let expected: Float = 0.5 - 1.0 / 16.0
        #expect(writtenVolume == expected)
    }

    @Test("4 volumeUp repeats from 0.5 land at 0.5 + 4·(1/16) = 0.75")
    func fourRepeatsCumulative() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var currentVolume: Float = 0.5
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .hardware,
                deviceName: "Test Device",
                currentVolume: currentVolume,
                currentMute: false,
                setVolume: { _, v in currentVolume = v },
                setMute: { _, _ in }
            )
        }
        let expected: Float = 0.5 + 4.0 * (1.0 / 16.0)
        #expect(currentVolume == expected)
    }

    @Test("3 volumeUp repeats from 0.9 clamp at 1.0")
    func repeatsClampAtOne() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var currentVolume: Float = 0.9
        for _ in 0..<3 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .hardware,
                deviceName: "Test Device",
                currentVolume: currentVolume,
                currentMute: false,
                setVolume: { _, v in currentVolume = v },
                setMute: { _, _ in }
            )
        }
        #expect(currentVolume == 1.0)
    }

    // MARK: - DDC repeat coalescing (AC #10)

    @Test("4 DDC repeats within 150 ms fire ≤ 3 setVolume calls (AC #10)")
    func ddcRepeatsCoalesced() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setVolumeCount = 0
        // Four rapid repeats with no sleep — the 80 ms floor will drop at least one.
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .ddc,
                deviceName: "Test Display",
                currentVolume: 0.5,
                currentMute: false,
                setVolume: { _, _ in setVolumeCount += 1 },
                setMute: { _, _ in }
            )
        }
        #expect(setVolumeCount <= 3)
    }

    @Test("Non-repeat DDC press always writes — floor applies only to repeats")
    func ddcNonRepeatAlwaysWrites() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setVolumeCount = 0
        for _ in 0..<3 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: false),
                deviceID: deviceID,
                tier: .ddc,
                deviceName: "Test Display",
                currentVolume: 0.5,
                currentMute: false,
                setVolume: { _, _ in setVolumeCount += 1 },
                setMute: { _, _ in }
            )
        }
        #expect(setVolumeCount == 3)
    }

    @Test("Hardware-tier repeats are NOT coalesced (no 80 ms floor)")
    func hardwareRepeatsNotCoalesced() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setVolumeCount = 0
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true),
                deviceID: deviceID,
                tier: .hardware,
                deviceName: "Test Device",
                currentVolume: 0.5,
                currentMute: false,
                setVolume: { _, _ in setVolumeCount += 1 },
                setMute: { _, _ in }
            )
        }
        #expect(setVolumeCount == 4)
    }

    // MARK: - Mute semantics on volume keys (volumeHUD / macOS parity)

    @Test("volumeUp while muted auto-unmutes (bug: F12 after F10 used to stay muted)")
    func volumeUpWhileMutedUnmutes() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: true,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, m in writtenMute = m }
        )
        let expected: Float = 0.5 + 1.0 / 16.0
        #expect(writtenMute == false)
        #expect(writtenVolume == expected)
    }

    @Test("volumeUp while unmuted does not touch mute state")
    func volumeUpWhileUnmutedDoesNotCallSetMute() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setMuteCalls = 0
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in setMuteCalls += 1 }
        )
        #expect(setMuteCalls == 0)
    }

    @Test("volumeDown to audible while muted auto-unmutes")
    func volumeDownToAudibleWhileMutedUnmutes() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: true,
            setVolume: { _, _ in },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenMute == false)
    }

    @Test("volumeDown to 0 while unmuted auto-mutes (macOS native parity)")
    func volumeDownToZeroAutoMutes() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        var writtenVolume: Float?
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 1.0 / 16.0,
            currentMute: false,
            setVolume: { _, v in writtenVolume = v },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenVolume == 0)
        #expect(writtenMute == true)
    }

    @Test("volumeDown already at 0 while muted is a no-op for mute")
    func volumeDownAtZeroWhileMutedNoOp() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var setMuteCalls = 0
        monitor.handleCore(
            event: .volumeDown(isRepeat: false),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.0,
            currentMute: true,
            setVolume: { _, _ in },
            setMute: { _, _ in setMuteCalls += 1 }
        )
        #expect(setMuteCalls == 0)
    }

    // MARK: - Mute toggle

    @Test("muteToggle from unmuted sets mute to true")
    func muteToggleOn() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        monitor.handleCore(
            event: .muteToggle,
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenMute == true)
    }

    @Test("muteToggle from muted sets mute to false")
    func muteToggleOff() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1
        var writtenMute: Bool?
        monitor.handleCore(
            event: .muteToggle,
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: true,
            setVolume: { _, _ in },
            setMute: { _, m in writtenMute = m }
        )
        #expect(writtenMute == false)
    }

    // MARK: - HUD show count

    @Test("handleCore calls HUD show once when popup is not visible")
    func hudShowCalledWhenPopupHidden() {
        let (monitor, hud, _, _) = makeMonitor(popupVisible: false)
        let deviceID: AudioDeviceID = 1
        #expect(hud.showCallCount == 0)
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in }
        )
        #expect(hud.showCallCount == 1)
    }

    @Test("handleCore does not call HUD show when popup is visible")
    func hudNotShownWhenPopupVisible() {
        let (monitor, hud, _, _) = makeMonitor(popupVisible: true)
        let deviceID: AudioDeviceID = 1
        monitor.handleCore(
            event: .volumeUp(isRepeat: false),
            deviceID: deviceID,
            tier: .software,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in }
        )
        #expect(hud.showCallCount == 0)
    }

    @Test("handleCore calls HUD show for repeat volumeUp when popup hidden (AC #7 per-call)")
    func hudShownForRepeat() {
        let (monitor, hud, _, _) = makeMonitor(popupVisible: false)
        let deviceID: AudioDeviceID = 1
        monitor.handleCore(
            event: .volumeUp(isRepeat: true),
            deviceID: deviceID,
            tier: .hardware,
            deviceName: "Test Device",
            currentVolume: 0.5,
            currentMute: false,
            setVolume: { _, _ in },
            setMute: { _, _ in }
        )
        #expect(hud.showCallCount == 1)
    }

    @Test("Software tier post-step gain differs from hardware tier by exactly the x² taper")
    func softwareVsHardwareStepDivergence() {
        let (monitor, _, _, _) = makeMonitor()
        let deviceID: AudioDeviceID = 1

        var softwareVolume: Float = 0.5
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: deviceID, tier: .software,
            deviceName: "Software Device", currentVolume: softwareVolume, currentMute: false,
            setVolume: { _, v in softwareVolume = v }, setMute: { _, _ in }
        )

        var hardwareVolume: Float = 0.5
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: deviceID, tier: .hardware,
            deviceName: "Hardware Device", currentVolume: hardwareVolume, currentMute: false,
            setVolume: { _, v in hardwareVolume = v }, setMute: { _, _ in }
        )

        #expect(abs(hardwareVolume - 0.5625) < 1e-5)
        let expectedSoftware = Float(pow(sqrt(0.5) + 1.0/16.0, 2))
        #expect(abs(softwareVolume - expectedSoftware) < 1e-5)
        #expect(softwareVolume != hardwareVolume)
    }

    // MARK: - Volume-feedback hook

    @Test("volumeUp on hardware tier invokes playFeedback with gain 1.0")
    func feedbackOnVolumeUpHardware() {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackGain: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { feedbackGain = $0 }
        )
        #expect(feedbackGain == 1.0)
    }

    @Test("volumeUp on software tier passes exactly the gain written to the device")
    func feedbackGainTracksSoftwareTier() {
        let (monitor, _, _, _) = makeMonitor()
        var written: Float?
        var feedbackGain: Float?
        monitor.handleCore(
            event: .volumeUp(isRepeat: false), deviceID: 1, tier: .software,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, v in written = v }, setMute: { _, _ in },
            playFeedback: { feedbackGain = $0 }
        )
        #expect(feedbackGain != nil)
        #expect(feedbackGain == written)  // the pop self-scales exactly like the tap gain
    }

    @Test("volumeDown invokes playFeedback")
    func feedbackOnVolumeDown() {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackCalls = 0
        monitor.handleCore(
            event: .volumeDown(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { _ in feedbackCalls += 1 }
        )
        #expect(feedbackCalls == 1)
    }

    @Test("muteToggle never invokes playFeedback (native parity)")
    func noFeedbackOnMuteToggle() {
        let (monitor, _, _, _) = makeMonitor()
        var feedbackCalls = 0
        monitor.handleCore(
            event: .muteToggle, deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 0.5, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, _ in },
            playFeedback: { _ in feedbackCalls += 1 }
        )
        #expect(feedbackCalls == 0)
    }

    @Test("DDC-coalesced repeats skip playFeedback along with setVolume")
    func feedbackCoalescedWithDDC() {
        let (monitor, _, _, _) = makeMonitor()
        var setVolumeCalls = 0
        var feedbackCalls = 0
        for _ in 0..<4 {
            monitor.handleCore(
                event: .volumeUp(isRepeat: true), deviceID: 1, tier: .ddc,
                deviceName: "Test Display", currentVolume: 0.5, currentMute: false,
                setVolume: { _, _ in setVolumeCalls += 1 }, setMute: { _, _ in },
                playFeedback: { _ in feedbackCalls += 1 }
            )
        }
        #expect(setVolumeCalls == 1)  // 4 synchronous repeats coalesce to one write
        #expect(feedbackCalls == setVolumeCalls)  // pop count mirrors actual volume writes
    }

    @Test("volumeDown reaching 0 auto-mutes AND still pops (spec behavior-table row)")
    func feedbackOnVolumeDownToZero() {
        let (monitor, _, _, settings) = makeMonitor()
        var appSettings = settings.appSettings
        appSettings.volumeHotkeyStep = .normal  // 1/16 step: currentVolume below lands exactly on 0
        settings.updateAppSettings(appSettings)
        var writtenMute: Bool?
        var feedbackCalls = 0
        monitor.handleCore(
            event: .volumeDown(isRepeat: false), deviceID: 1, tier: .hardware,
            deviceName: "Test Device", currentVolume: 1.0 / 16.0, currentMute: false,
            setVolume: { _, _ in }, setMute: { _, m in writtenMute = m },
            playFeedback: { _ in feedbackCalls += 1 }
        )
        #expect(writtenMute == true)
        #expect(feedbackCalls == 1)
    }
}
