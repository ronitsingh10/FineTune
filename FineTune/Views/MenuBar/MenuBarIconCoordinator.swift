// FineTune/Views/MenuBar/MenuBarIconCoordinator.swift
// Owns NSStatusBarButton.image mutation. FluidMenuBarExtra sets the image
// once at init and never touches it again, so we locate the button by
// walking NSApp.windows for the NSStatusBarButton whose accessibilityTitle
// was set to "FineTune" by the library, and crossfade images directly.

import AppKit
import AudioToolbox
import Observation
import os

@MainActor
final class MenuBarIconCoordinator {
    private let deviceVolumeMonitor: DeviceVolumeMonitor
    private let settings: SettingsManager
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "MenuBarIconCoordinator")

    private weak var cachedButton: NSStatusBarButton?
    private var flashWorkItem: DispatchWorkItem?
    private var flashActiveSymbol: String?
    private var lastObservedDeviceID: AudioDeviceID?
    private var started = false

    init(deviceVolumeMonitor: DeviceVolumeMonitor, settings: SettingsManager) {
        self.deviceVolumeMonitor = deviceVolumeMonitor
        self.settings = settings
    }

    /// Begin observing volume / mute / style and apply state to the menu bar button.
    /// Idempotent; safe to call from the app-init path even before the status item exists.
    func start() {
        guard !started else { return }
        started = true
        lastObservedDeviceID = deviceVolumeMonitor.defaultDeviceID
        attemptInitialApply(retriesLeft: 20)
        scheduleApplyTracking()
        scheduleDeviceChangeTracking()
    }

    /// Cancel pending work and drop references. Called on app termination.
    func stop() {
        flashWorkItem?.cancel()
        flashWorkItem = nil
        cachedButton = nil
    }

    /// Transient device-icon flash. Applies to every style; fires on media keys and device changes.
    /// If the same symbol is already flashing, extends the timer rather than restarting the fade —
    /// prevents mid-fade pops when device-change and media-key triggers coincide.
    func flashDevice() {
        let symbol = currentDeviceSymbol()
        let alreadyShowingSame = (flashActiveSymbol == symbol)
        flashActiveSymbol = symbol
        if !alreadyShowingSame {
            apply()
        }

        flashWorkItem?.cancel()
        let duration = flashDuration()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashActiveSymbol = nil
            self.apply()
        }
        flashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    // MARK: - State

    private func computeState() -> MenuBarIconState {
        if let symbol = flashActiveSymbol {
            return .deviceFlash(symbol: symbol)
        }
        let id = deviceVolumeMonitor.defaultDeviceID
        let volume = deviceVolumeMonitor.volumes[id] ?? 0
        let muted = deviceVolumeMonitor.muteStates[id] ?? false
        return MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: volume,
            muted: muted
        )
    }

    private func currentDeviceSymbol() -> String {
        let id = deviceVolumeMonitor.defaultDeviceID
        guard id.isValid else { return "hifispeaker" }
        return id.suggestedIconSymbol()
    }

    private func flashDuration() -> TimeInterval {
        // Matches HUDWindowController.hideDelay so the icon and HUD fade in lockstep.
        return 1.1
    }

    // MARK: - Apply

    private func apply() {
        guard let button = resolveButton() else { return }
        let state = computeState()
        guard let image = state.image.nsImage() else { return }
        addFadeTransition(to: button)
        button.image = image
    }

    private func attemptInitialApply(retriesLeft: Int) {
        if resolveButton() != nil {
            apply()
            return
        }
        guard retriesLeft > 0 else {
            logger.error("Menu bar button not found after 20 tries (1s); icon will remain at FluidMenuBarExtra placeholder until next state change")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attemptInitialApply(retriesLeft: retriesLeft - 1)
        }
    }

    private func scheduleApplyTracking() {
        withObservationTracking {
            let id = deviceVolumeMonitor.defaultDeviceID
            _ = deviceVolumeMonitor.volumes[id]
            _ = deviceVolumeMonitor.muteStates[id]
            _ = settings.appSettings.menuBarIconStyle
            _ = settings.appSettings.hudStyle
        } onChange: { [weak self] in
            // onChange fires in willSet — the tracked properties are still at their
            // pre-change values inside this closure. Re-register synchronously so the
            // next mutation isn't dropped, then defer apply() to a Task so it reads
            // committed (post-setter) values.
            MainActor.assumeIsolated {
                self?.scheduleApplyTracking()
            }
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }
    }

    private func scheduleDeviceChangeTracking() {
        withObservationTracking {
            _ = deviceVolumeMonitor.defaultDeviceID
        } onChange: { [weak self] in
            // See scheduleApplyTracking — deferred read so flashDevice sees the NEW
            // defaultDeviceID, not the pre-change value. Otherwise the flash shows
            // the old device's icon (e.g. AirPods while we just switched to MacBook).
            MainActor.assumeIsolated {
                self?.scheduleDeviceChangeTracking()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newID = self.deviceVolumeMonitor.defaultDeviceID
                if let prev = self.lastObservedDeviceID, prev != newID, newID.isValid {
                    self.flashDevice()
                }
                self.lastObservedDeviceID = newID
            }
        }
    }

    // MARK: - Button + image

    private func resolveButton() -> NSStatusBarButton? {
        if let cached = cachedButton { return cached }
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let button = findStatusBarButton(in: contentView, matching: "FineTune") {
                button.wantsLayer = true
                cachedButton = button
                return button
            }
        }
        return nil
    }

    private func findStatusBarButton(in view: NSView, matching title: String) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton, button.accessibilityTitle() == title {
            return button
        }
        for subview in view.subviews {
            if let match = findStatusBarButton(in: subview, matching: title) {
                return match
            }
        }
        return nil
    }

    private func addFadeTransition(to button: NSStatusBarButton) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "iconFade")
    }
}
