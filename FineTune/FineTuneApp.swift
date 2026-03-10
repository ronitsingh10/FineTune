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

    func applicationWillTerminate(_ notification: Notification) {
        // Flush settings synchronously so debounced saves aren't lost on quit.
        // This is the single, authoritative flush path — driven by the delegate
        // which holds the same AudioEngine instance that the UI writes through.
        audioEngine?.settingsManager.flushSync()
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
}

@main
struct FineTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @StateObject private var updateManager = UpdateManager()
    @State private var showMenuBarExtra = true
    @State private var themeManager = ThemeManager()

    /// Icon style captured at launch (doesn't change during runtime)
    private let launchIconStyle: MenuBarIconStyle

    /// Icon name captured at launch for SF Symbols
    private let launchSystemImageName: String?

    /// Icon name captured at launch for asset catalog
    private let launchAssetImageName: String?

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
        ThemedContainer(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor,
            updateManager: updateManager,
            launchIconStyle: launchIconStyle
        )
        .environment(themeManager)
    }

    init() {
        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        OrphanedTapCleanup.destroyOrphanedDevices()

        let settings = SettingsManager()
        let engine = AudioEngine(settingsManager: settings)
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

        // Settings flush on termination is handled by AppDelegate.applicationWillTerminate
        // to avoid multiple observers firing if FineTuneApp.init() is called more than once.
    }
}

// MARK: - ThemedContainer
// A dedicated View so that @Observable ThemeManager changes trigger re-renders of
// .tint() and .preferredColorScheme(). An App's @ViewBuilder body doesn't re-evaluate
// on @Observable changes, so we need a real View body to track them.
private struct ThemedContainer: View {
    let audioEngine: AudioEngine
    let deviceVolumeMonitor: DeviceVolumeMonitor
    let updateManager: UpdateManager
    let launchIconStyle: MenuBarIconStyle

    @Environment(ThemeManager.self) private var theme

    var body: some View {
        MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: deviceVolumeMonitor,
            updateManager: updateManager,
            launchIconStyle: launchIconStyle
        )
        .tint(theme.accentColor)
        .preferredColorScheme(theme.colorScheme)
    }
}
