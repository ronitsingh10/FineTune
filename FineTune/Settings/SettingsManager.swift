// FineTune/Settings/SettingsManager.swift
import Foundation
import os
import ServiceManagement

// MARK: - Pinned App Info

struct PinnedAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - App-Wide Settings Enums

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default` = "Default"
    case speaker = "Speaker"
    case waveform = "Waveform"
    case equalizer = "Equalizer"

    var id: String { rawValue }

    /// The icon name - either asset catalog name or SF Symbol
    var iconName: String {
        switch self {
        case .default: return "MenuBarIcon"
        case .speaker: return "speaker.wave.2.fill"
        case .waveform: return "waveform"
        case .equalizer: return "slider.vertical.3"
        }
    }

    /// Whether this uses an SF Symbol (vs asset catalog image)
    var isSystemSymbol: Bool {
        self != .default
    }
}

// MARK: - App-Wide Settings Model

struct AppSettings: Codable, Equatable {
    // General
    var launchAtLogin: Bool = false
    var menuBarIconStyle: MenuBarIconStyle = .default

    // Audio
    var defaultNewAppVolume: Float = 1.0      // 100% (unity gain)
    var maxVolumeBoost: Float = 2.0           // 200% max
    var defaultEQEnabled: Bool = true         // Whether EQ is enabled by default for new apps

    // Input Device Lock
    var lockInputDevice: Bool = true          // Prevent auto-switching input device

    // Notifications
    var showDeviceDisconnectAlerts: Bool = true
}

// MARK: - Settings Manager

@Observable
@MainActor
final class SettingsManager {
    private var settings: Settings
    private var saveTask: Task<Void, Never>?
    private let settingsURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "SettingsManager")

    struct Settings: Codable {
        var version: Int = 7
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appEQSettings: [String: EQSettings] = [:]  // bundleID → EQ settings
        var appSettings: AppSettings = AppSettings()  // App-wide settings
        var systemSoundsFollowsDefault: Bool = true  // Whether system sounds follows macOS default
        var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]  // bundleID → selection mode
        var appSelectedDeviceUIDs: [String: [String]] = [:]  // bundleID → array of device UIDs for multi mode
        var lockedInputDeviceUID: String? = nil  // User's preferred input device (for input lock feature)
        var pinnedApps: Set<String> = []  // Persistence identifiers of pinned apps
        var pinnedAppInfo: [String: PinnedAppInfo] = [:]  // Persistence identifier → app metadata
    }

    init(directory: URL? = nil) {
        let baseDir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FineTune")
        self.settingsURL = baseDir.appendingPathComponent("settings.json")
        self.settings = Settings()
        loadFromDisk()
    }

    func getVolume(for identifier: String) -> Float? {
        settings.appVolumes[identifier]
    }

    func setVolume(for identifier: String, to volume: Float) {
        settings.appVolumes[identifier] = volume
        scheduleSave()
    }

    func getDeviceRouting(for identifier: String) -> String? {
        settings.appDeviceRouting[identifier]
    }

    func setDeviceRouting(for identifier: String, deviceUID: String) {
        settings.appDeviceRouting[identifier] = deviceUID
        scheduleSave()
    }

    /// Returns true if the app follows system default (no explicit device routing saved)
    func isFollowingDefault(for identifier: String) -> Bool {
        settings.appDeviceRouting[identifier] == nil
    }

    /// Clears device routing for an app, making it follow system default
    func setFollowDefault(for identifier: String) {
        settings.appDeviceRouting.removeValue(forKey: identifier)
        scheduleSave()
    }

    // MARK: - System Sounds Settings

    /// Returns whether system sounds should follow the macOS default output device
    var isSystemSoundsFollowingDefault: Bool {
        settings.systemSoundsFollowsDefault
    }

    /// Sets whether system sounds should follow the macOS default output device
    func setSystemSoundsFollowDefault(_ follows: Bool) {
        settings.systemSoundsFollowsDefault = follows
        scheduleSave()
    }

    func getMute(for identifier: String) -> Bool? {
        settings.appMutes[identifier]
    }

    func setMute(for identifier: String, to muted: Bool) {
        settings.appMutes[identifier] = muted
        scheduleSave()
    }

    func getEQSettings(for appIdentifier: String) -> EQSettings {
        if let savedSettings = settings.appEQSettings[appIdentifier] {
            return savedSettings
        }
        // Return default EQ with isEnabled based on user preference
        return EQSettings(isEnabled: settings.appSettings.defaultEQEnabled)
    }

    func setEQSettings(_ eqSettings: EQSettings, for appIdentifier: String) {
        settings.appEQSettings[appIdentifier] = eqSettings
        scheduleSave()
    }

    // MARK: - Device Selection Mode

    func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode? {
        settings.appDeviceSelectionMode[identifier]
    }

    func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode) {
        settings.appDeviceSelectionMode[identifier] = mode
        scheduleSave()
    }

    // MARK: - Selected Device UIDs (Multi Mode)

    func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? {
        guard let uids = settings.appSelectedDeviceUIDs[identifier] else { return nil }
        return Set(uids)
    }

    func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
        settings.appSelectedDeviceUIDs[identifier] = Array(uids)
        scheduleSave()
    }

    // MARK: - Input Device Lock

    var lockedInputDeviceUID: String? {
        settings.lockedInputDeviceUID
    }

    func setLockedInputDeviceUID(_ uid: String?) {
        settings.lockedInputDeviceUID = uid
        scheduleSave()
    }

    // MARK: - Pinned Apps

    func pinApp(_ identifier: String, info: PinnedAppInfo) {
        settings.pinnedApps.insert(identifier)
        settings.pinnedAppInfo[identifier] = info
        scheduleSave()
    }

    func unpinApp(_ identifier: String) {
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isPinned(_ identifier: String) -> Bool {
        settings.pinnedApps.contains(identifier)
    }

    /// Returns metadata for all pinned apps
    func getPinnedAppInfo() -> [PinnedAppInfo] {
        settings.pinnedApps.compactMap { settings.pinnedAppInfo[$0] }
    }

    // MARK: - App-Wide Settings

    var appSettings: AppSettings {
        settings.appSettings
    }

    func updateAppSettings(_ newSettings: AppSettings) {
        // Handle launch at login separately via ServiceManagement
        if newSettings.launchAtLogin != settings.appSettings.launchAtLogin {
            setLaunchAtLogin(newSettings.launchAtLogin)
        }
        settings.appSettings = newSettings
        scheduleSave()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }

    /// Returns the actual launch at login status from the system
    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Reset All Settings

    /// Resets all per-app settings and app-wide settings to defaults
    func resetAllSettings() {
        settings.appVolumes.removeAll()
        settings.appDeviceRouting.removeAll()
        settings.appMutes.removeAll()
        settings.appEQSettings.removeAll()
        settings.pinnedApps.removeAll()
        settings.pinnedAppInfo.removeAll()
        settings.appSettings = AppSettings()
        settings.systemSoundsFollowsDefault = true
        settings.lockedInputDeviceUID = nil

        // Also unregister from launch at login
        try? SMAppService.mainApp.unregister()

        scheduleSave()
        logger.info("Reset all settings to defaults")
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try JSONDecoder().decode(Settings.self, from: data)
            logger.debug("Loaded settings with \(self.settings.appVolumes.count) volumes, \(self.settings.appDeviceRouting.count) device routings, \(self.settings.appMutes.count) mutes, \(self.settings.appEQSettings.count) EQ settings")
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription)")
            // Backup corrupted file before resetting
            let backupURL = settingsURL.deletingPathExtension().appendingPathExtension("backup.json")
            try? FileManager.default.removeItem(at: backupURL)  // Remove old backup if exists
            try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
            logger.warning("Backed up corrupted settings to \(backupURL.lastPathComponent)")
            settings = Settings()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeToDisk()
        }
    }

    /// Immediately writes pending changes to disk.
    /// Call this on app termination to prevent data loss.
    func flushSync() {
        saveTask?.cancel()
        saveTask = nil
        writeToDisk()
    }

    private func writeToDisk() {
        do {
            let directory = settingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)

            logger.debug("Saved settings")
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }
}
