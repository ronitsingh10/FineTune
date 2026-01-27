// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import AppKit
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine = FineTuneApp.sharedEngine else {
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)

        for url in urls {
            urlHandler.handleURL(url)
        }
    }
}

@main
struct FineTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @StateObject private var updateManager = UpdateManager()
    @State private var showMenuBarExtra = true

    /// Icon style captured at launch (doesn't change during runtime)
    private let launchIconStyle: MenuBarIconStyle

    /// Icon name captured at launch for SF Symbols
    private let launchSystemImageName: String?

    /// Icon name captured at launch for asset catalog
    private let launchAssetImageName: String?
    
    /// Shared reference for AppDelegate access
    static var sharedEngine: AudioEngine?

    var body: some Scene {
        // Use dual scenes with captured icon names - only one is visible based on icon type
        FluidMenuBarExtra("FineTune", systemImage: launchSystemImageName ?? "speaker.wave.2", isInserted: systemIconBinding) {
            menuBarContent
        }

        FluidMenuBarExtra("FineTune", image: launchAssetImageName ?? "MenuBarIcon", isInserted: assetIconBinding) {
            menuBarContent
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }

    /// Show SF Symbol menu bar when launch style is a system symbol
    private var systemIconBinding: Binding<Bool> {
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
        let settings = SettingsManager()
        let engine = AudioEngine(settingsManager: settings)
        _audioEngine = State(initialValue: engine)
        
        // Store for AppDelegate access
        FineTuneApp.sharedEngine = engine

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
            settings.flushSync()
        }
    }
}
