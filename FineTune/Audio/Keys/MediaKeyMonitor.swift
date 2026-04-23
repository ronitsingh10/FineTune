// FineTune/Audio/Keys/MediaKeyMonitor.swift
import AppKit
import AudioToolbox
import CoreGraphics
import os

/// Intercepts F10/F11/F12 via a `CGEventTap`, swallows them so the native HUD
/// does not double-fire, and drives the default output device.
@MainActor
final class MediaKeyMonitor {
    // MARK: - Collaborators

    private let decoder: any MediaKeyEventDecoding
    private let audioEngine: AudioEngine
    private let settingsManager: SettingsManager
    private let accessibility: any AccessibilityTrustProviding
    private let hudController: HUDWindowController
    private let popupVisibility: PopupVisibilityService
    private let mediaKeyStatus: MediaKeyStatus
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "MediaKeyMonitor")

    /// Step size applied per keypress (1/16 matches Apple's default cadence).
    private let volumeStep: Float = 1.0 / 16.0

    // MARK: - Tap state

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Second `.tapDisabledBy*` inside the watchdog window marks the feature offline.
    private var disableWatchdogTask: Task<Void, Never>?
    private(set) var watchdogOpen: Bool = false

    /// 80 ms floor between DDC-tier repeats — DDC write queues saturate at key-repeat rate.
    var lastDDCRepeatTime: DispatchTime?

    private var ghostTapProbeTask: Task<Void, Never>?

    /// CGEventTaps are per-session; wake leaves them enabled-but-inert.
    private var workspaceObservers: [NSObjectProtocol] = []

    var onRunLoopSourceRemoved: (() -> Void)?

    /// Optional coordinator notified on every volume/mute key event so the menu bar icon
    /// can flash the current device's transport symbol. Wired by FineTuneApp after init.
    var iconCoordinator: MenuBarIconCoordinator?

    init(
        decoder: any MediaKeyEventDecoding,
        audioEngine: AudioEngine,
        settingsManager: SettingsManager,
        accessibility: any AccessibilityTrustProviding,
        hudController: HUDWindowController,
        popupVisibility: PopupVisibilityService,
        mediaKeyStatus: MediaKeyStatus
    ) {
        self.decoder = decoder
        self.audioEngine = audioEngine
        self.settingsManager = settingsManager
        self.accessibility = accessibility
        self.hudController = hudController
        self.popupVisibility = popupVisibility
        self.mediaKeyStatus = mediaKeyStatus
        subscribeToWorkspaceLifecycle()
    }

    deinit {
        // C callback holds an unretained pointer to self; runloop source must not outlive us.
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { nc.removeObserver(observer) }
    }

    // MARK: - Lifecycle

    /// Idempotent. No-op unless media keys are enabled and Accessibility is trusted.
    func start() {
        logger.info("DIAG start() entry tap=\(self.tap != nil ? "present" : "nil") enabled=\(self.settingsManager.appSettings.mediaKeyControlEnabled) axTrusted=\(self.accessibility.isTrusted) listenAccess=\(CGPreflightListenEventAccess()) postAccess=\(CGPreflightPostEventAccess())")
        guard tap == nil else { return }
        guard settingsManager.appSettings.mediaKeyControlEnabled else {
            logger.debug("Media key control disabled in settings; tap not installed")
            return
        }
        guard accessibility.isTrusted else {
            logger.info("Accessibility not trusted; tap not installed")
            return
        }

        // NX_SYSDEFINED = 14 (from <IOLLEvent.h>); CGEventType has no Swift case.
        let mask = CGEventMask(1 << 14)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: userInfo
        ) else {
            logger.error("CGEvent.tapCreate returned nil — media keys will not be intercepted")
            mediaKeyStatus.isOffline = true
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        self.tap = newTap
        self.runLoopSource = source
        self.mediaKeyStatus.isOffline = false
        logger.info("DIAG tap installed tapIsEnabled=\(CGEvent.tapIsEnabled(tap: newTap))")
    }

    /// Reconciles tap state against settings + Accessibility trust. Idempotent.
    func reconcile() {
        if settingsManager.appSettings.mediaKeyControlEnabled && accessibility.isTrusted {
            // Post-regrant taps can come up inert; arm a probe to surface that to the user.
            let wasOffline = (tap == nil)
            start()
            if wasOffline && tap != nil {
                armGhostTapProbe()
            }
        } else {
            cancelGhostTapProbe()
            stop()
        }
    }

    // MARK: - Workspace lifecycle (sleep/wake, session)

    /// Re-enable on wake/session-activate; disable on sleep/deactivate.
    private func subscribeToWorkspaceLifecycle() {
        let nc = NSWorkspace.shared.notificationCenter
        func add(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            workspaceObservers.append(token)
        }
        add(NSWorkspace.didWakeNotification) { [weak self] in self?.handleWake() }
        add(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.handleWake() }
        add(NSWorkspace.willSleepNotification) { [weak self] in self?.handleSuspend() }
        add(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.handleSuspend() }
    }

    private func handleWake() {
        guard let tap else {
            reconcile()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Media key tap re-enabled after wake / session activation")
        armGhostTapProbe()
    }

    private func handleSuspend() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        logger.info("Media key tap disabled for sleep / session resign")
    }

    // MARK: - Ghost-tap probe

    /// Checks `tapIsEnabled` ~1.5s after install; marks offline if the kernel dropped it.
    private func armGhostTapProbe() {
        cancelGhostTapProbe()
        ghostTapProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                self.logger.error("Ghost-tap probe: tap reports disabled after regrant/wake — marking offline")
                self.mediaKeyStatus.isOffline = true
            }
            self.ghostTapProbeTask = nil
        }
    }

    private func cancelGhostTapProbe() {
        ghostTapProbeTask?.cancel()
        ghostTapProbeTask = nil
    }

    /// Tears down the tap + runloop source. Must be called before dealloc.
    func stop() {
        disableWatchdogTask?.cancel()
        disableWatchdogTask = nil
        watchdogOpen = false
        cancelGhostTapProbe()

        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            onRunLoopSourceRemoved?()
        }
        tap = nil
        runLoopSource = nil
        logger.info("Media key tap removed")
    }

    // MARK: - Event handling

    /// Applies a decoded `MediaKeyEvent` to the default output device.
    func handle(_ event: MediaKeyEvent) {
        let volumeMonitor = audioEngine.deviceVolumeMonitor
        let deviceID = volumeMonitor.defaultDeviceID
        guard deviceID.isValid else {
            logger.debug("Ignoring media key: no valid default output device")
            return
        }
        let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
        let deviceName = audioEngine.deviceMonitor.outputDevices.first { $0.id == deviceID }?.name ?? ""
        handleCore(
            event: event,
            deviceID: deviceID,
            tier: tier,
            deviceName: deviceName,
            currentVolume: volumeMonitor.volumes[deviceID] ?? 0,
            currentMute: volumeMonitor.muteStates[deviceID] ?? false,
            setVolume: { id, vol in volumeMonitor.setVolume(for: id, to: vol) },
            setMute:   { id, mute in volumeMonitor.setMute(for: id, to: mute) }
        )
    }

    /// Volume/mute state machine. `.ddc` tier coalesces repeats to an 80 ms floor;
    /// hardware/software tiers pass them through. Mute repeats are dropped upstream.
    func handleCore(
        event: MediaKeyEvent,
        deviceID: AudioDeviceID,
        tier: VolumeControlTier,
        deviceName: String,
        currentVolume: Float,
        currentMute: Bool,
        setVolume: (AudioDeviceID, Float) -> Void,
        setMute: (AudioDeviceID, Bool) -> Void
    ) {
        let shouldShowHUD = !popupVisibility.isVisible
        logger.info("DIAG handleCore event=\(String(describing: event)) shouldShowHUD=\(shouldShowHUD) popupVisible=\(self.popupVisibility.isVisible) device=\(deviceName, privacy: .public)")

        switch event {
        case .volumeUp(let isRepeat):
            if isRepeat && tier == .ddc && isDDCRepeatCoalesced() {
                logger.debug("DDC repeat coalesced")
                return
            }
            let newVolume = min(1.0, currentVolume + volumeStep)
            // Volume-up from muted unmutes (system HUD parity).
            if currentMute {
                setMute(deviceID, false)
            }
            setVolume(deviceID, newVolume)
            if shouldShowHUD {
                hudController.show(volume: newVolume, mute: false, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()

        case .volumeDown(let isRepeat):
            if isRepeat && tier == .ddc && isDDCRepeatCoalesced() {
                logger.debug("DDC repeat coalesced")
                return
            }
            let newVolume = max(0, currentVolume - volumeStep)
            let willBeSilent = newVolume <= 0.001
            // muted+audible → unmute; unmuted+silent → auto-mute (system HUD parity).
            if currentMute && !willBeSilent {
                setMute(deviceID, false)
            } else if !currentMute && willBeSilent {
                setMute(deviceID, true)
            }
            setVolume(deviceID, newVolume)
            if shouldShowHUD {
                hudController.show(volume: newVolume, mute: willBeSilent, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()

        case .muteToggle:
            let newMute = !currentMute
            setMute(deviceID, newMute)
            if shouldShowHUD {
                hudController.show(volume: currentVolume, mute: newMute, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()
        }
    }

    /// `true` if this repeat falls inside the 80 ms floor and should be dropped.
    private func isDDCRepeatCoalesced() -> Bool {
        let now = DispatchTime.now()
        if let last = lastDDCRepeatTime {
            let deltaNs = now.uptimeNanoseconds &- last.uptimeNanoseconds
            if deltaNs < 80 * 1_000_000 { return true }
        }
        lastDDCRepeatTime = now
        return false
    }

    // MARK: - Tap-disabled watchdog

    /// Kernel disabled the tap. One-shot re-enable; second disable inside 5s marks offline.
    func handleTapDisabled() {
        // Runtime Accessibility revocation — tear down and let the permission card surface.
        // `isOffline` stays false here; it's reserved for kernel-stall ("Retry") scenarios.
        if !accessibility.isTrusted {
            logger.warning("Tap disabled and Accessibility no longer trusted — stopping tap")
            disableWatchdogTask?.cancel()
            disableWatchdogTask = nil
            watchdogOpen = false
            stop()
            accessibility.refresh()
            return
        }

        logger.info("Tap disabled by kernel — attempting re-enable")

        if watchdogOpen {
            // Second disable inside the 5s window — feature is offline.
            logger.error("Second tap-disable inside watchdog window; marking media keys offline")
            mediaKeyStatus.isOffline = true
            disableWatchdogTask?.cancel()
            disableWatchdogTask = nil
            watchdogOpen = false
            return
        }

        watchdogOpen = true
        disableWatchdogTask?.cancel()
        disableWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.watchdogOpen = false
            self?.disableWatchdogTask = nil
        }

        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Callback bridge

    /// Returns `true` if the caller should swallow the event.
    fileprivate func processSystemDefined(_ cgEvent: CGEvent) -> Bool {
        // Pass through if disabled mid-race; never silently eat another app's media keys.
        guard settingsManager.appSettings.mediaKeyControlEnabled else { return false }
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return false }
        // Subtype 8 is the media-key channel; aux-button / brightness are pass-through.
        guard nsEvent.subtype.rawValue == 8 else { return false }
        let data1 = nsEvent.data1
        guard let mediaEvent = decoder.decode(data1: data1) else { return false }

        hudController.swallowObserved()
        handle(mediaEvent)
        return true
    }
}

// MARK: - CGEventTap C callback

// Tap installs on `CFRunLoopGetMain()` so this runs on main; `assumeIsolated`
// preserves ordering against the next event (a Task-hop would reorder).
private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            monitor.handleTapDisabled()
        }
        return nil
    }

    // NX_SYSDEFINED = 14; no Swift case in CGEventType.
    guard type.rawValue == 14 else {
        return Unmanaged.passUnretained(event)
    }

    let shouldSwallow = MainActor.assumeIsolated {
        monitor.processSystemDefined(event)
    }
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
