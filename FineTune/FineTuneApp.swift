// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import AppKit
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var audioEngine: AudioEngine?

    /// Off-screen NSWindow kept alive for the process lifetime so WindowServer wires
    /// `.cghidEventTap` into our event routing. Without this, a pure LSUIElement menu
    /// bar app receives no media-key events from the HID tap until the first real
    /// window (the FluidMenuBarExtra popup) is shown — the "first window primes event
    /// taps" AppKit activation cycle. See fix/media-key-cold-launch-prime.
    private var hidPrimerWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        primeEventTapPipeline()
    }

    private func primeEventTapPipeline() {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.orderFront(nil)
        window.orderOut(nil)
        hidPrimerWindow = window
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine = audioEngine else {
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)

        for url in urls {
            urlHandler.handleURL(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

@main
struct FineTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @State private var accessibility: AccessibilityPermissionService
    @State private var mediaKeyStatus: MediaKeyStatus
    @State private var popupVisibility: PopupVisibilityService
    @State private var hudController: HUDWindowController
    @State private var mediaKeyMonitor: MediaKeyMonitor
    @State private var iconCoordinator: MenuBarIconCoordinator
    @StateObject private var updateManager = UpdateManager()
    @State private var showMenuBarExtra = true

    /// Snapshot icon computed at launch from the user's chosen style and the current
    /// default-device volume/mute. The coordinator keeps it in sync afterwards.
    private let launchIconImage: NSImage

    var body: some Scene {
        FluidMenuBarExtra("FineTune", image: launchIconImage, isInserted: $showMenuBarExtra) {
            menuBarContent
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        // `deviceVolumeMonitor` is declared as `any DeviceVolumeProviding` on
        // AudioEngine so tests can inject mocks; in production it's always the
        // concrete `DeviceVolumeMonitor` that this view consumes directly.
        MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
            updateManager: updateManager,
            permission: audioEngine.permission,
            accessibility: accessibility,
            mediaKeyStatus: mediaKeyStatus,
            popupVisibility: popupVisibility,
            hudController: hudController,
            mediaKeyMonitor: mediaKeyMonitor
        )
    }

    init() {
        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        OrphanedTapCleanup.destroyOrphanedDevices()

        let settings = SettingsManager()
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(permission: permission, settingsManager: settings, autoEQProfileManager: profileManager)
        _audioEngine = State(initialValue: engine)

        // Media keys / HUD services — instantiated at app scope so the tap
        // and HUD panel outlive popup open/close cycles.
        let accessibilityService = AccessibilityPermissionService()
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)

        // Wire the interactive Tahoe slider back to the device volume monitor.
        // Mirrors the mute semantics applied for media-key drags (auto-unmute
        // when ramping above 0 from muted; auto-mute when dragging down to 0)
        // so the HUD slider and F11/F12 behave identically.
        hud.volumeWriter = { [weak engine] newVolume in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            let deviceID = volumeMonitor.defaultDeviceID
            guard deviceID.isValid else { return }
            let currentMute = volumeMonitor.muteStates[deviceID] ?? false
            let willBeSilent = newVolume <= 0.001
            if currentMute && !willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: false)
            } else if !currentMute && willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: true)
            }
            volumeMonitor.setVolume(for: deviceID, to: newVolume)
        }

        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibilityService,
            hudController: hud,
            popupVisibility: popupService,
            mediaKeyStatus: statusService
        )
        _accessibility = State(initialValue: accessibilityService)
        _mediaKeyStatus = State(initialValue: statusService)
        _popupVisibility = State(initialValue: popupService)
        _hudController = State(initialValue: hud)
        _mediaKeyMonitor = State(initialValue: monitor)

        let coordinator = MenuBarIconCoordinator(deviceVolumeMonitor: engine.deviceVolumeMonitor as! DeviceVolumeMonitor, settings: settings)
        monitor.iconCoordinator = coordinator
        // Defer start() so NSApplication.shared is fully bootstrapped before we walk NSApp.windows.
        DispatchQueue.main.async { [coordinator] in coordinator.start() }
        _iconCoordinator = State(initialValue: coordinator)

        // Render the scene's first frame with the user's chosen style instead of a generic
        // placeholder, so non-speaker styles don't briefly flash a speaker icon at launch.
        let launchVolumeMonitor = engine.deviceVolumeMonitor
        let launchID = launchVolumeMonitor.defaultDeviceID
        let launchState = MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false
        )
        launchIconImage = launchState.image.nsImage()
            ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "FineTune")!

        // Start Accessibility polling immediately so `isTrustedCached` is live
        // before the user first opens Settings. The trust-flip callback wires
        // the monitor to reconcile its tap state whenever trust changes — this
        // is the single source of truth for retroactive start/stop (a `.onChange`
        // inside MenuBarPopupView would miss flips when the popup is closed).
        accessibilityService.onTrustChanged = { [weak monitor] _ in
            monitor?.reconcile()
        }
        accessibilityService.start()
        monitor.reconcile()

        // Pass engine to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine

        if permission.status == .unknown {
            permission.request()
        }

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set delegate before requesting authorization so willPresent is called
        UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        // Flush debounced settings + tear down the CGEventTap before dealloc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings, monitor, accessibilityService, hud, coordinator] _ in
            MainActor.assumeIsolated {
                coordinator.stop()
                monitor.stop()
                accessibilityService.stop()
                hud.shutdown()
            }
            settings.flushSync()
        }
    }
}
