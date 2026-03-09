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
        var version: Int = 8
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appSettings: AppSettings = AppSettings()  // App-wide settings
        var systemSoundsFollowsDefault: Bool = true  // Whether system sounds follows macOS default
        var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]  // bundleID → selection mode
        var appSelectedDeviceUIDs: [String: [String]] = [:]  // bundleID → array of device UIDs for multi mode
        var lockedInputDeviceUID: String? = nil  // User's preferred input device (for input lock feature)
        var pinnedApps: Set<String> = []  // Persistence identifiers of pinned apps
        var pinnedAppInfo: [String: PinnedAppInfo] = [:]  // Persistence identifier → app metadata

        // DDC monitor speaker volumes (keyed by CoreAudio device UID for stability across reboots)
        var ddcVolumes: [String: Int] = [:]       // device UID → volume (0-100)
        var ddcMuteStates: [String: Bool] = [:]   // device UID → software mute state
        var ddcSavedVolumes: [String: Int] = [:]  // device UID → volume before mute

        // Device priority (ordered device UIDs, highest priority first)
        var outputDevicePriority: [String] = []
        var inputDevicePriority: [String] = []
        var hiddenOutputDeviceUIDs: Set<String> = []
        var hiddenInputDeviceUIDs: Set<String> = []

        // Preferred nominal sample rate per device UID
        var preferredDeviceSampleRates: [String: Double] = [:]
        // Device-wide EQ settings keyed by output device UID
        var deviceEQSettings: [String: EQSettings] = [:]

        // Apps excluded from FineTune processing and UI
        var excludedAppIdentifiers: Set<String> = []
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

    func getDeviceEQSettings(for deviceUID: String) -> EQSettings {
        settings.deviceEQSettings[deviceUID] ?? EQSettings.flat
    }

    func setDeviceEQSettings(_ eqSettings: EQSettings, for deviceUID: String) {
        settings.deviceEQSettings[deviceUID] = eqSettings
        scheduleSave()
    }

    /// Resolves effective EQ for an app using device-level EQ only.
    func getEffectiveEQSettings(deviceUID: String?) -> EQSettings {
        if let deviceUID {
            return settings.deviceEQSettings[deviceUID] ?? EQSettings.flat
        }
        return EQSettings.flat
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

    // MARK: - DDC Monitor Volume

    func getDDCVolume(for deviceUID: String) -> Int? {
        settings.ddcVolumes[deviceUID]
    }

    func setDDCVolume(for deviceUID: String, to volume: Int) {
        settings.ddcVolumes[deviceUID] = volume
        scheduleSave()
    }

    func getDDCMuteState(for deviceUID: String) -> Bool {
        settings.ddcMuteStates[deviceUID] ?? false
    }

    func setDDCMuteState(for deviceUID: String, to muted: Bool) {
        settings.ddcMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getDDCSavedVolume(for deviceUID: String) -> Int? {
        settings.ddcSavedVolumes[deviceUID]
    }

    func setDDCSavedVolume(for deviceUID: String, to volume: Int) {
        settings.ddcSavedVolumes[deviceUID] = volume
        scheduleSave()
    }

    // MARK: - Device Priority

    var devicePriorityOrder: [String] {
        settings.outputDevicePriority
    }

    func setDevicePriorityOrder(_ uids: [String]) {
        settings.outputDevicePriority = uids
        scheduleSave()
    }

    func ensureDeviceInPriority(_ uid: String) {
        guard !settings.outputDevicePriority.contains(uid) else { return }
        settings.outputDevicePriority.append(uid)
        scheduleSave()
    }

    var inputDevicePriorityOrder: [String] {
        settings.inputDevicePriority
    }

    func setInputDevicePriorityOrder(_ uids: [String]) {
        settings.inputDevicePriority = uids
        scheduleSave()
    }

    func ensureInputDeviceInPriority(_ uid: String) {
        guard !settings.inputDevicePriority.contains(uid) else { return }
        settings.inputDevicePriority.append(uid)
        scheduleSave()
    }

    // MARK: - Hidden Devices

    func isOutputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenOutputDeviceUIDs.contains(uid)
    }

    func isInputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenInputDeviceUIDs.contains(uid)
    }

    func setOutputDeviceHidden(_ uid: String, hidden: Bool) {
        if hidden {
            settings.hiddenOutputDeviceUIDs.insert(uid)
        } else {
            settings.hiddenOutputDeviceUIDs.remove(uid)
        }
        scheduleSave()
    }

    func setInputDeviceHidden(_ uid: String, hidden: Bool) {
        if hidden {
            settings.hiddenInputDeviceUIDs.insert(uid)
        } else {
            settings.hiddenInputDeviceUIDs.remove(uid)
        }
        scheduleSave()
    }

    // MARK: - Device Sample Rate Preferences

    func getPreferredSampleRate(for deviceUID: String) -> Double? {
        settings.preferredDeviceSampleRates[deviceUID]
    }

    func setPreferredSampleRate(for deviceUID: String, to rate: Double?) {
        if let rate {
            settings.preferredDeviceSampleRates[deviceUID] = rate
        } else {
            settings.preferredDeviceSampleRates.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    // MARK: - Excluded Apps

    func isExcludedApp(_ identifier: String) -> Bool {
        settings.excludedAppIdentifiers.contains(identifier)
    }

    func excludeApp(_ identifier: String) {
        settings.excludedAppIdentifiers.insert(identifier)
        scheduleSave()
    }

    func includeApp(_ identifier: String) {
        settings.excludedAppIdentifiers.remove(identifier)
        scheduleSave()
    }

    func excludedApps() -> [String] {
        Array(settings.excludedAppIdentifiers).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        settings.pinnedApps.removeAll()
        settings.pinnedAppInfo.removeAll()
        settings.appSettings = AppSettings()
        settings.systemSoundsFollowsDefault = true
        settings.lockedInputDeviceUID = nil
        settings.ddcVolumes.removeAll()
        settings.ddcMuteStates.removeAll()
        settings.ddcSavedVolumes.removeAll()
        settings.outputDevicePriority.removeAll()
        settings.inputDevicePriority.removeAll()
        settings.hiddenOutputDeviceUIDs.removeAll()
        settings.hiddenInputDeviceUIDs.removeAll()
        settings.preferredDeviceSampleRates.removeAll()
        settings.deviceEQSettings.removeAll()
        settings.excludedAppIdentifiers.removeAll()

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
            logger.debug("Loaded settings with \(self.settings.appVolumes.count) volumes, \(self.settings.appDeviceRouting.count) device routings, \(self.settings.appMutes.count) mutes")
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
            let snapshot = settings
            let url = settingsURL
            let data = try? JSONEncoder().encode(snapshot)
            guard let data else { return }
            Task.detached(priority: .utility) {
                do {
                    try Self.writeData(data, to: url)
                } catch {
                    // Avoid actor hops/logging on audio-critical paths; failures are
                    // non-fatal and will retry on the next settings mutation.
                }
            }
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
            let data = try JSONEncoder().encode(settings)
            try Self.writeData(data, to: settingsURL)

            logger.debug("Saved settings")
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    private nonisolated static func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
