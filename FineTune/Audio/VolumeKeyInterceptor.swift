// FineTune/Audio/VolumeKeyInterceptor.swift
//
// Intercepts macOS volume key events for software-volume devices (e.g. Samsung TVs
// via HDMI that have no hardware volume control) and redirects them to software gain.
//
// Uses NSEvent global + local monitors. The system OSD will still briefly appear
// (hollow, since it reads hardware volume) but our SoftwareVolumeHUD overlays
// the correct level in the bottom-right corner.
//
// STEP SIZE: 1/100 = 1% per keypress.

import AppKit
import AudioToolbox
import os

private let NX_KEYTYPE_SOUND_UP:   Int = 0
private let NX_KEYTYPE_SOUND_DOWN: Int = 1
private let NX_KEYTYPE_MUTE:       Int = 7

@MainActor
final class VolumeKeyInterceptor {

    private weak var audioEngine: AudioEngine?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "VolumeKeyInterceptor")
    private let stepSize: Float = 1.0 / 100.0

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    // MARK: - Lifecycle

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self else { return event }
            // Consume the event for SW-only devices so macOS doesn't also act on it
            if self.isSwVolumeEvent(event) {
                self.handleEvent(event)
                return nil
            }
            return event
        }

        logger.info("Volume key interceptor started")
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

    // MARK: - Unused stubs kept for call-site compatibility

    func updateSoftwareDeviceFlag() { }

    // MARK: - Event handling

    private func isSwVolumeEvent(_ event: NSEvent) -> Bool {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let isVolumeKey = keyCode == NX_KEYTYPE_SOUND_UP
                       || keyCode == NX_KEYTYPE_SOUND_DOWN
                       || keyCode == NX_KEYTYPE_MUTE
        guard isVolumeKey else { return false }
        guard let engine = audioEngine else { return false }
        let id = engine.deviceVolumeMonitor.defaultDeviceID
        return id != .unknown && !id.hasOutputVolumeControl()
    }

    private func handleEvent(_ event: NSEvent) {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return }
        let d1      = event.data1
        let keyCode = (d1 & 0xFFFF0000) >> 16
        let keyDown = ((d1 & 0x0000FF00) >> 8) == 0x0A
        guard keyDown else { return }

        guard let engine = audioEngine else { return }
        let defaultDeviceID = engine.deviceVolumeMonitor.defaultDeviceID
        guard defaultDeviceID != .unknown,
              !defaultDeviceID.hasOutputVolumeControl() else { return }
        guard let device = engine.deviceMonitor.devicesByID[defaultDeviceID] else { return }

        switch keyCode {
        case NX_KEYTYPE_SOUND_UP:
            logger.debug("Volume up → SW gain for \(device.name)")
            adjustGain(for: device, delta: +stepSize)

        case NX_KEYTYPE_SOUND_DOWN:
            logger.debug("Volume down → SW gain for \(device.name)")
            adjustGain(for: device, delta: -stepSize)

        case NX_KEYTYPE_MUTE:
            logger.debug("Mute toggle → SW mute for \(device.name)")
            let current = engine.getSoftwareMute(for: device)
            engine.setSoftwareMute(for: device, to: !current)

        default:
            break
        }
    }

    // MARK: - Gain adjustment

    private func adjustGain(for device: AudioDevice, delta: Float) {
        guard let engine = audioEngine else { return }
        if delta > 0 && engine.getSoftwareMute(for: device) {
            engine.setSoftwareMute(for: device, to: false)
        }
        let new = max(0.0, min(1.0, engine.getSoftwareVolume(for: device) + delta))
        engine.setSoftwareVolume(for: device, to: new)
    }
}
