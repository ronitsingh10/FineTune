// FineTune/Shortcuts/ShortcutsRegistry.swift
import AppKit
import Foundation
import KeyboardShortcuts
import os

@MainActor
protocol AudioEngineDispatching: AnyObject {
    var apps: [AudioApp] { get }
    func setVolume(for app: AudioApp, to volume: Float)
    func setMute(for app: AudioApp, to muted: Bool)
    func toggleMute(for app: AudioApp)
    func currentVolume(for app: AudioApp) -> Float
    func isMuted(for app: AudioApp) -> Bool
    func isAudibleNow(bundleID: String) -> Bool
}

@MainActor
protocol PerAppHUDPresenting: AnyObject {
    func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double)
    func showPerAppMuteHUD(app: AudioApp, isMuted: Bool)
    func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?)
}

/// Bridges `KeyboardShortcuts` (Carbon-backed global hotkey library, MIT) to
/// FineTune's settings layer.
///
/// Responsibilities:
///   1. Load: on `start()`, push every persisted shortcut from `AppSettings`
///      into `KeyboardShortcuts` and register a `onKeyDown` handler that
///      dispatches the matching `ShortcutAction`.
///   2. Save: vend `recordCallback(for:)` closures that the UI's `Recorder`
///      passes as its `onChange` parameter. When the user records a new
///      chord, the callback writes the change back to `SettingsManager`,
///      keeping `settings.json` the source of truth.
///
/// Why no async-stream observer for write-back: `KeyboardShortcuts.events(...)`
/// only emits `.keyDown` / `.keyUp`, not "shortcut changed". The library's only
/// shortcut-mutation hook is the `Recorder.onChange` per-instance callback,
/// which we wire from the UI. This keeps re-entrancy impossible by construction:
/// programmatic `setShortcut(_:for:)` from `start()` never fires `Recorder.onChange`.
@MainActor
@Observable
final class ShortcutsRegistry {
    private static let logger = Logger(
        subsystem: "com.finetuneapp.FineTune",
        category: "ShortcutsRegistry"
    )

    private let settings: SettingsManager
    private let popupController: any MenuBarPopupControlling
    private let resolver: any TargetAppResolving
    private let audioEngine: any AudioEngineDispatching
    private let hud: any PerAppHUDPresenting
    private var didStart = false

    /// Software-emulated key-repeat timing. Carbon hot keys don't auto-repeat,
    /// so holding the chord runs this loop. Values match macOS keyboard defaults.
    private static let repeatInitialDelay: Duration = .milliseconds(450)
    private static let repeatInterval: Duration = .milliseconds(60)

    private var repeatTasks: [ShortcutAction: Task<Void, Never>] = [:]

    init(
        settings: SettingsManager,
        popupController: any MenuBarPopupControlling,
        resolver: any TargetAppResolving,
        audioEngine: any AudioEngineDispatching,
        hud: any PerAppHUDPresenting
    ) {
        self.settings = settings
        self.popupController = popupController
        self.resolver = resolver
        self.audioEngine = audioEngine
        self.hud = hud
    }

    /// Stable `KeyboardShortcuts.Name` per action. The raw string is part of
    /// the persistence contract — don't change it without a migration.
    func name(for action: ShortcutAction) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name(stableID(for: action))
    }

    /// Routes a fired action to its handler. Exposed `internal` so tests can
    /// drive it directly without faking a global key event.
    func dispatch(_ action: ShortcutAction) {
        switch action {
        case .togglePopup:
            popupController.toggle()
        case .targetAppVolumeUp:
            adjustTargetVolume(direction: +1)
        case .targetAppVolumeDown:
            adjustTargetVolume(direction: -1)
        case .targetAppMuteToggle:
            toggleTargetMute()
        }
    }

    // MARK: - Per-app dispatch

    private func adjustTargetVolume(direction: Int) {
        guard let app = resolveTargetAudioApp() else { return }
        let sliderDelta = settings.appSettings.volumeHotkeyStep.sliderDelta * Double(direction)

        let currentGain = audioEngine.currentVolume(for: app)
        let currentSlider = VolumeMapping.gainToSlider(currentGain)
        let nextSlider = max(0.0, min(1.0, currentSlider + sliderDelta))
        let nextGain = VolumeMapping.sliderToGain(nextSlider)

        let currentMute = audioEngine.isMuted(for: app)
        let willBeSilent = nextSlider <= 0.001

        if direction > 0 {
            if currentMute {
                audioEngine.setMute(for: app, to: false)
            }
        } else {
            if currentMute && !willBeSilent {
                audioEngine.setMute(for: app, to: false)
            } else if !currentMute && willBeSilent {
                audioEngine.setMute(for: app, to: true)
            }
        }
        audioEngine.setVolume(for: app, to: nextGain)
        if settings.appSettings.volumeHUDEnabled {
            hud.showPerAppVolumeHUD(app: app, sliderFraction: nextSlider)
        }
    }

    private func toggleTargetMute() {
        guard let app = resolveTargetAudioApp() else { return }
        audioEngine.toggleMute(for: app)
        if settings.appSettings.volumeHUDEnabled {
            hud.showPerAppMuteHUD(app: app, isMuted: audioEngine.isMuted(for: app))
        }
    }

    private func startRepeating(action: ShortcutAction) {
        guard action.supportsRepeat else { return }
        repeatTasks[action]?.cancel()
        repeatTasks[action] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.repeatInitialDelay)
            while !Task.isCancelled {
                guard let self else { return }
                self.dispatch(action)
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func stopRepeating(action: ShortcutAction) {
        repeatTasks[action]?.cancel()
        repeatTasks[action] = nil
    }

    private func resolveTargetAudioApp() -> AudioApp? {
        let candidates = audioEngine.apps
            .compactMap { $0.bundleID }
            .filter { audioEngine.isAudibleNow(bundleID: $0) }

        guard let bundleID = resolver.resolveTargetBundleID(audibleCandidates: candidates) else {
            if settings.appSettings.volumeHUDEnabled {
                hud.showPerAppNotControlledHUD(displayName: nil, bundleID: nil, icon: nil)
            }
            return nil
        }
        if let app = audioEngine.apps.first(where: { $0.bundleID == bundleID }) {
            return app
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if settings.appSettings.volumeHUDEnabled {
            hud.showPerAppNotControlledHUD(
                displayName: running?.localizedName,
                bundleID: bundleID,
                icon: running?.icon
            )
        }
        return nil
    }

    /// Idempotent. Subsequent calls are no-ops. Safe to call from a SwiftUI
    /// `.task` modifier on the popup content.
    func start() {
        guard !didStart else { return }
        didStart = true

        for action in ShortcutAction.allCases {
            let actionName = name(for: action)

            if let codable = settings.appSettings.customShortcuts[action.rawValue] {
                KeyboardShortcuts.setShortcut(codable.keyboardShortcut, for: actionName)
            }

            KeyboardShortcuts.onKeyDown(for: actionName) { [weak self] in
                self?.dispatch(action)
                self?.startRepeating(action: action)
            }
            KeyboardShortcuts.onKeyUp(for: actionName) { [weak self] in
                self?.stopRepeating(action: action)
            }
        }

        Self.logger.debug("ShortcutsRegistry started; \(ShortcutAction.allCases.count) action(s) registered")
    }

    /// Returns a closure suitable for `KeyboardShortcuts.Recorder(for:onChange:)`.
    /// When the user records or clears a chord, the closure mirrors the change
    /// into `SettingsManager.appSettings.customShortcuts`.
    ///
    /// The return type carries `@MainActor` even though the library's parameter
    /// type does not — this works today because `KeyboardShortcuts.Recorder` is
    /// SwiftUI-presented and its `Coordinator.handleChange(_:)` runs on the
    /// MainActor, so passing a more-isolated function value satisfies the
    /// less-isolated parameter via implicit conversion. If a future library
    /// version dispatches `onChange` from a non-MainActor context, that becomes
    /// a runtime crash; the annotation is the contract that makes it surface
    /// loudly rather than silently corrupt MainActor-isolated state.
    func recordCallback(for action: ShortcutAction) -> @MainActor (KeyboardShortcuts.Shortcut?) -> Void {
        return { [weak self] shortcut in
            self?.handleRecorderChange(shortcut: shortcut, for: action)
        }
    }

    private func handleRecorderChange(shortcut: KeyboardShortcuts.Shortcut?, for action: ShortcutAction) {
        var app = settings.appSettings
        if let shortcut {
            app.customShortcuts[action.rawValue] = ShortcutCodable.from(shortcut)
        } else {
            app.customShortcuts[action.rawValue] = nil
        }
        settings.appSettings = app
    }

    private func stableID(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "toggle-popup"
        case .targetAppVolumeUp: "frontmost-app-volume-up"
        case .targetAppVolumeDown: "frontmost-app-volume-down"
        case .targetAppMuteToggle: "frontmost-app-mute-toggle"
        }
    }
}

extension AudioEngine: AudioEngineDispatching {}
extension HUDWindowController: PerAppHUDPresenting {}
