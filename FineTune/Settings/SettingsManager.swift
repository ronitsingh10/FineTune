// FineTune/Settings/SettingsManager.swift
import Foundation
import os
import ServiceManagement

@Observable
@MainActor
final class SettingsManager {
    private var settings: Settings
    private var saveTask: Task<Void, Never>?
    private let settingsURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "SettingsManager")

    struct Settings: Codable {
        var version: Int = 5
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appEQSettings: [String: EQSettings] = [:]  // bundleID → EQ settings
        var appPreferences: AppPreferences = AppPreferences()
    }

    /// Global app preferences (not per-app settings)
    struct AppPreferences: Codable {
        var menuBarIcon: MenuBarIconOption = .default
        var startAtLogin: Bool = false
        var autoCheckForUpdates: Bool = true
        var lastUpdateCheck: Date?
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

    func getMute(for identifier: String) -> Bool? {
        settings.appMutes[identifier]
    }

    func setMute(for identifier: String, to muted: Bool) {
        settings.appMutes[identifier] = muted
        scheduleSave()
    }

    func getEQSettings(for appIdentifier: String) -> EQSettings {
        return settings.appEQSettings[appIdentifier] ?? EQSettings.flat
    }

    func setEQSettings(_ eqSettings: EQSettings, for appIdentifier: String) {
        settings.appEQSettings[appIdentifier] = eqSettings
        scheduleSave()
    }

    /// Current app preferences (global settings)
    var appPreferences: AppPreferences {
        settings.appPreferences
    }

    /// Updates the menu bar icon preference
    func setMenuBarIcon(_ icon: MenuBarIconOption) {
        settings.appPreferences.menuBarIcon = icon
        scheduleSave()
    }

    /// Whether the app should start at login
    var startAtLogin: Bool {
        get { settings.appPreferences.startAtLogin }
        set {
            settings.appPreferences.startAtLogin = newValue
            updateLoginItem(enabled: newValue)
            scheduleSave()
        }
    }

    /// Whether the app should automatically check for updates
    var autoCheckForUpdates: Bool {
        get { settings.appPreferences.autoCheckForUpdates }
        set {
            settings.appPreferences.autoCheckForUpdates = newValue
            scheduleSave()
        }
    }

    /// The last time an update check was performed
    var lastUpdateCheck: Date? {
        get { settings.appPreferences.lastUpdateCheck }
        set {
            settings.appPreferences.lastUpdateCheck = newValue
            scheduleSave()
        }
    }

    /// Returns true if an automatic update check should be performed.
    /// Checks if auto-check is enabled AND more than 1 hour has passed since the last check.
    func shouldCheckForUpdates() -> Bool {
        guard autoCheckForUpdates else { return false }
        guard let lastCheck = lastUpdateCheck else { return true }
        return Date().timeIntervalSince(lastCheck) > 3600  // 1 hour
    }

    /// Records the current time as the last update check timestamp.
    func recordUpdateCheck() {
        lastUpdateCheck = Date()
    }

    /// Syncs the startAtLogin setting with the actual system login item state
    /// Call this on app launch to handle cases where user changed it via System Settings
    func syncLoginItemState() {
        let currentStatus = SMAppService.mainApp.status
        let isRegistered = currentStatus == .enabled
        if settings.appPreferences.startAtLogin != isRegistered {
            settings.appPreferences.startAtLogin = isRegistered
            scheduleSave()
            logger.debug("Synced startAtLogin to \(isRegistered) based on system login item status")
        }
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.debug("Registered app as login item")
            } else {
                try SMAppService.mainApp.unregister()
                logger.debug("Unregistered app as login item")
            }
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription)")
            // Revert setting on failure
            settings.appPreferences.startAtLogin = !enabled
        }
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
