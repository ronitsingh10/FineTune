// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import AppKit
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var audioEngine: AudioEngine?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine = audioEngine else {
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)

        for url in urls {
            urlHandler.handleURL(url)
        }
    }
}

@MainActor
final class MenuBarSpeakerIconUpdater {
    private weak var audioEngine: AudioEngine?
    private var timer: Timer?
    private var lastSymbolName: String?
    private let statusItemTitle = "FineTune"
    private weak var statusItemButton: NSStatusBarButton?

    func start(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let audioEngine else { return }
        let monitor = audioEngine.deviceVolumeMonitor
        let defaultDeviceID = monitor.defaultDeviceID
        let volume = monitor.volumes[defaultDeviceID] ?? 1.0
        let isMuted = monitor.muteStates[defaultDeviceID] ?? false
        let level = max(0.0, min(1.0, Double(volume)))

        let symbol: String
        if isMuted || level <= 0.0001 {
            symbol = "speaker.slash.fill"
        } else if level <= 1.0 / 3.0 {
            symbol = "speaker.wave.1.fill"
        } else if level <= 2.0 / 3.0 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }

        guard symbol != lastSymbolName else { return }
        if updateStatusButtonImage(symbolName: symbol) {
            lastSymbolName = symbol
        }
    }

    @discardableResult
    private func updateStatusButtonImage(symbolName: String) -> Bool {
        let button: NSStatusBarButton
        if let cached = statusItemButton {
            button = cached
        } else {
            guard let discovered = findFineTuneStatusButton() else { return false }
            statusItemButton = discovered
            button = discovered
        }
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: statusItemTitle) else { return false }
        image.isTemplate = true
        // Avoid re-entrant layout warnings by applying image update on next runloop tick.
        DispatchQueue.main.async {
            button.image = image
        }
        return true
    }

    private func findFineTuneStatusButton() -> NSStatusBarButton? {
        // Primary path: query NSStatusBar's status item list.
        if let statusItems = NSStatusBar.system.value(forKey: "_statusItems") as? [NSStatusItem] {
            for item in statusItems {
                guard let button = item.button else { continue }
                if isFineTuneStatusButton(button) {
                    return button
                }
            }
        }

        // Fallback path: walk view hierarchy for OS/package variations where _statusItems isn't available.
        let app = NSApplication.shared
        for window in app.windows {
            guard let root = window.contentView else { continue }
            if let found = findStatusButton(in: root) {
                return found
            }
        }

        return nil
    }

    private func isFineTuneStatusButton(_ button: NSStatusBarButton) -> Bool {
        if button.accessibilityTitle() == statusItemTitle {
            return true
        }
        if button.toolTip == statusItemTitle {
            return true
        }
        if button.title == statusItemTitle {
            return true
        }
        return false
    }

    private func findStatusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton, isFineTuneStatusButton(button) {
            return button
        }
        for subview in view.subviews {
            if let found = findStatusButton(in: subview) {
                return found
            }
        }
        return nil
    }
}

@main
struct FineTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @StateObject private var updateManager = UpdateManager()
    @State private var showMenuBarExtra = true
    private let menuBarSpeakerIconUpdater: MenuBarSpeakerIconUpdater?

    /// Icon style captured at launch (doesn't change during runtime)
    private let launchIconStyle: MenuBarIconStyle

    /// Icon name captured at launch for SF Symbols
    private let launchSystemImageName: String?

    /// Icon name captured at launch for asset catalog
    private let launchAssetImageName: String?

    var body: some Scene {
        // Single status item scene; for speaker style, icon image is updated in-place by updater.
        FluidMenuBarExtra("FineTune", systemImage: launchSystemImageName ?? "speaker.wave.2", isInserted: staticSystemIconBinding) {
            menuBarContent
        }

        FluidMenuBarExtra("FineTune", image: launchAssetImageName ?? "MenuBarIcon", isInserted: assetIconBinding) {
            menuBarContent
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }

    private var staticSystemIconBinding: Binding<Bool> {
        Binding(
            get: { showMenuBarExtra && launchIconStyle.isSystemSymbol },
            set: { showMenuBarExtra = $0 }
        )
    }

    /// Show asset catalog menu bar when launch style is not a system symbol
    private var assetIconBinding: Binding<Bool> {
        Binding(
            get: { showMenuBarExtra && !launchIconStyle.isSystemSymbol },
            set: { showMenuBarExtra = $0 }
        )
    }

    @ViewBuilder
    private var menuBarContent: some View {
        MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor,
            updateManager: updateManager,
            launchIconStyle: launchIconStyle
        )
    }

    init() {
        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        OrphanedTapCleanup.destroyOrphanedDevices()

        let settings = SettingsManager()
        let profileManager = AutoEQProfileManager()
        let engine = AudioEngine(settingsManager: settings, autoEQProfileManager: profileManager)
        _audioEngine = State(initialValue: engine)

        // Pass engine to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine

        // Capture icon style at launch - requires restart to change
        let iconStyle = settings.appSettings.menuBarIconStyle
        launchIconStyle = iconStyle

        // Capture the correct icon name based on type
        if iconStyle.isSystemSymbol {
            launchSystemImageName = iconStyle.iconName
            launchAssetImageName = nil
        } else {
            launchSystemImageName = nil
            launchAssetImageName = iconStyle.iconName
        }

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        // Flush settings on app termination to prevent data loss from debounced saves
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings] _ in
            Task { @MainActor in
                settings.flushSync()
            }
        }

        if iconStyle == .speaker {
            let updater = MenuBarSpeakerIconUpdater()
            updater.start(audioEngine: engine)
            menuBarSpeakerIconUpdater = updater
        } else {
            menuBarSpeakerIconUpdater = nil
        }
    }
}
