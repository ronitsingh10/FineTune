// FineTune/Audio/VolumeKeyInterceptor.swift
//
// Intercepts macOS volume key events (keyboard F11/F12, volume knob, Touch Bar)
// and redirects them to software gain when the current default output device
// has no hardware volume control (e.g. Samsung/LG TVs via HDMI).
//
// APPROACH: We install BOTH a global monitor AND a local monitor.
//
//   • addGlobalMonitorForEvents — fires for events dispatched to OTHER apps.
//     Covers the common case where FineTune is a background menu-bar process.
//
//   • addLocalMonitorForEvents  — fires for events dispatched to THIS app.
//     Covers the case where the FineTune popup is open and it is the frontmost
//     application. Without this, the global monitor is silent when FineTune is
//     the key window, so the knob appeared to "only work when GUI was visible"
//     (actually it was only working via the UI slider, never via the knob).
//
// STEP SIZE: 1/100 = 1% per keypress (user-requested; macOS native is 1/16).
//
// THREAD SAFETY: Both monitor callbacks fire on the main thread. All AudioEngine
// calls are @MainActor so no extra dispatch is required.

import AppKit
import AudioToolbox
import os

// NX media key codes (from <IOKit/hidsystem/ev_keymap.h>)
private let NX_KEYTYPE_SOUND_UP:   Int = 0
private let NX_KEYTYPE_SOUND_DOWN: Int = 1
private let NX_KEYTYPE_MUTE:       Int = 7

@MainActor
final class VolumeKeyInterceptor {

    private weak var audioEngine: AudioEngine?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "VolumeKeyInterceptor")

    /// 1% per keypress — user-friendly for TV-style coarse speakers
    private let stepSize: Float = 1.0 / 100.0

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    // MARK: - Lifecycle

    func start() {
        guard globalMonitor == nil else { return }

        // Global monitor: fires when volume keys go to OTHER apps (FineTune is background)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleEvent(event)
        }

        // Local monitor: fires when volume keys come to THIS app (popup is open/frontmost)
        // Must return the event so normal FineTune key handling still works.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleEvent(event)
            return event  // always pass through — don't swallow the event
        }

        logger.info("Volume key interceptor started (global + local monitors)")
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        logger.info("Volume key interceptor stopped")
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: NSEvent) {
        // Media keys arrive as NSEvent.EventType.systemDefined (14), subtype 8
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return }

        // Bit layout of data1: [31:16] key code | [15:8] key state | [7:0] key repeat
        let data1   = event.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyDown = ((data1 & 0x0000FF00) >> 8) == 0x0A   // 0x0A = key pressed

        guard keyDown else { return }   // ignore key-up events

        guard let engine = audioEngine else { return }

        // Only intercept for the default output device when it has no hardware volume.
        // For all other devices fall through and let macOS handle it normally.
        let defaultDeviceID = engine.deviceVolumeMonitor.defaultDeviceID
        guard defaultDeviceID != .unknown,
              !defaultDeviceID.hasOutputVolumeControl() else { return }

        guard let device = engine.deviceMonitor.devicesByID[defaultDeviceID] else { return }

        switch Int(keyCode) {
        case NX_KEYTYPE_SOUND_UP:
            logger.debug("Volume up → SW gain for \(device.name)")
            adjustGain(for: device, delta: +stepSize)

        case NX_KEYTYPE_SOUND_DOWN:
            logger.debug("Volume down → SW gain for \(device.name)")
            adjustGain(for: device, delta: -stepSize)

        case NX_KEYTYPE_MUTE:
            logger.debug("Mute toggle → SW mute for \(device.name)")
            let currentMute = engine.getSoftwareMute(for: device)
            engine.setSoftwareMute(for: device, to: !currentMute)
            showOSD(for: device)

        default:
            break
        }
    }

    // MARK: - Gain Adjustment

    private func adjustGain(for device: AudioDevice, delta: Float) {
        guard let engine = audioEngine else { return }

        // Unmute on volume-up if currently software-muted
        if delta > 0 && engine.getSoftwareMute(for: device) {
            engine.setSoftwareMute(for: device, to: false)
        }

        let current = engine.getSoftwareVolume(for: device)
        let new = max(0.0, min(1.0, current + delta))
        engine.setSoftwareVolume(for: device, to: new)

        showOSD(for: device, volume: new)
    }

    // MARK: - On-Screen Display (OSD)

    /// Shows the native translucent volume HUD via BezelServices.
    /// OSD level is 0–16 (the 17 notches macOS draws on the HUD bar).
    /// We scale our 0–100% range to that same 0–16 range so the bar looks right.
    private func showOSD(for device: AudioDevice, volume: Float? = nil) {
        guard let engine = audioEngine else { return }

        let effectiveVolume = volume ?? (engine.getSoftwareMute(for: device) ? 0 : engine.getSoftwareVolume(for: device))
        let isMuted = engine.getSoftwareMute(for: device) || effectiveVolume == 0

        if let bsBundle = Bundle(path: "/System/Library/PrivateFrameworks/BezelServices.framework"),
           bsBundle.load(),
           let sym = CFBundleGetFunctionPointerForName(bsBundle.cfBundle, "OSDUIHelper_SetVolume" as CFString) {
            typealias OSDFunc = @convention(c) (UInt32, Bool) -> Void
            let osd = unsafeBitCast(sym, to: OSDFunc.self)
            let level = UInt32(round(effectiveVolume * 16.0))
            osd(level, isMuted)
            return
        }

        logger.debug("BezelServices unavailable — no OSD shown")
    }
}

// MARK: - Bundle helper

private extension Bundle {
    var cfBundle: CFBundle {
        CFBundleCreate(kCFAllocatorDefault, bundleURL as CFURL)
    }
}
