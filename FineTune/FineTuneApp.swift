// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

@main
struct FineTuneApp: App {
    @State private var audioEngine: AudioEngine
    @State private var settingsManager: SettingsManager
    @State private var updateChecker: UpdateChecker
    @State private var showMenuBarExtra = true

    /// Menu bar icon determined at launch (requires restart to change)
    private let menuBarIcon: MenuBarIconOption

    var body: some Scene {
        FluidMenuBarExtra("FineTune", image: menuBarImage, isInserted: $showMenuBarExtra) {
            menuBarContent
        }

        Settings { EmptyView() }
    }

    /// Creates the menu bar icon NSImage based on the stored icon option
    /// Note: Icon is read at init time; changes require app restart
    private var menuBarImage: NSImage {
        if menuBarIcon.isSystemImage {
            return NSImage(systemSymbolName: menuBarIcon.imageName, accessibilityDescription: "FineTune")
                ?? NSImage(named: "MenuBarIcon")!
        } else {
            return NSImage(named: menuBarIcon.imageName)!
        }
    }

    private var menuBarContent: some View {
        MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor,
            settingsManager: settingsManager,
            updateChecker: updateChecker,
            currentMenuBarIcon: menuBarIcon
        )
    }

    init() {
        let settings = SettingsManager()
        settings.syncLoginItemState()  // Sync with system login items in case user changed it via System Settings
        let engine = AudioEngine(settingsManager: settings)
        let checker = UpdateChecker()
        _audioEngine = State(initialValue: engine)
        _settingsManager = State(initialValue: settings)
        _updateChecker = State(initialValue: checker)
        menuBarIcon = settings.appPreferences.menuBarIcon

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set up notification delegate to handle notification clicks (e.g., update available)
        UNUserNotificationCenter.current().delegate = UpdateNotificationDelegate.shared

        // Request notification authorization (for device disconnect alerts and update notifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
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
            settings.flushSync()
        }

        // Start periodic update checks (includes initial check after 3s delay)
        Task { @MainActor in
            checker.startPeriodicChecks(settingsManager: settings)
        }
    }
}
