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

// MARK: - Ignored App Info

struct IgnoredAppInfo: Codable, Equatable {
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

    // Input Device Lock
    var lockInputDevice: Bool = true          // Prevent auto-switching input device

    // Device Volume
    var softwareDeviceVolumeEnabled: Bool = false  // Software volume for unsupported output devices (opt-in)
    var showVirtualOutputDevices: Bool = false     // Show virtual output devices (e.g. BlackHole, Loopback) in the list (opt-in)

    // Notifications
    var showDeviceDisconnectAlerts: Bool = true

    // Audio Processing
    var loudnessCompensationEnabled: Bool = false  // ISO 226:2023 equal-loudness contour compensation
    var loudnessEqualizationEnabled: Bool = false  // Real-time loudness equalization

    init() {}

    mutating func setUnifiedLoudnessEnabled(_ enabled: Bool) {
        loudnessCompensationEnabled = enabled
        loudnessEqualizationEnabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarIconStyle = try c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .default
        defaultNewAppVolume = try c.decodeIfPresent(Float.self, forKey: .defaultNewAppVolume) ?? 1.0
        lockInputDevice = try c.decodeIfPresent(Bool.self, forKey: .lockInputDevice) ?? true
        softwareDeviceVolumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .softwareDeviceVolumeEnabled) ?? false
        showVirtualOutputDevices = try c.decodeIfPresent(Bool.self, forKey: .showVirtualOutputDevices) ?? false
        showDeviceDisconnectAlerts = try c.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? true
        loudnessCompensationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessCompensationEnabled) ?? false
        loudnessEqualizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessEqualizationEnabled) ?? false
    }
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
        var version: Int = 10
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appBoosts: [String: Float] = [:]  // bundleID → boost rawValue (1.0, 2.0, 3.0, 4.0)
        var appEQSettings: [String: EQSettings] = [:]  // bundleID → EQ settings
        var appSettings: AppSettings = AppSettings()  // App-wide settings
        var systemSoundsFollowsDefault: Bool = true  // Whether system sounds follows macOS default
        var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]  // bundleID → selection mode
        var appSelectedDeviceUIDs: [String: [String]] = [:]  // bundleID → array of device UIDs for multi mode
        var lockedInputDeviceUID: String? = nil  // Current locked input device (updated on fallback)
        var preferredInputDeviceUID: String? = nil  // User's intended input device (survives disconnect)
        var pinnedApps: Set<String> = []  // Persistence identifiers of pinned apps
        var pinnedAppInfo: [String: PinnedAppInfo] = [:]  // Persistence identifier → app metadata
        var ignoredApps: Set<String> = []  // Persistence identifiers of hidden apps
        var ignoredAppInfo: [String: IgnoredAppInfo] = [:]  // Persistence identifier → app metadata

        // DDC monitor speaker volumes (keyed by CoreAudio device UID for stability across reboots)
        var ddcVolumes: [String: Int] = [:]       // device UID → volume (0-100)
        var ddcMuteStates: [String: Bool] = [:]   // device UID → software mute state
        var ddcSavedVolumes: [String: Int] = [:]  // device UID → volume before mute

        // Software-backed output volumes for devices without native volume control
        var softwareDeviceVolumes: [String: Float] = [:]      // device UID → visible volume (0.0-1.0)
        var softwareDeviceMuteStates: [String: Bool] = [:]    // device UID → software mute state
        var softwareDeviceSavedVolumes: [String: Float] = [:] // device UID → volume before mute

        // Device priority (ordered device UIDs, highest priority first)
        var outputDevicePriority: [String] = []
        var inputDevicePriority: [String] = []

        // Per-device AutoEQ headphone correction
        var deviceAutoEQ: [String: AutoEQSelection] = [:]  // deviceUID → selection
        var favoriteAutoEQProfiles: Set<String> = []  // profile IDs
        var autoEQPreampEnabled: Bool = true  // Use profile preamp vs bypass (rely on limiter)

        // User-created EQ presets (named EQ curves)
        var userEQPresets: [UserEQPreset] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 9
            appVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }  // Clamp old volumes > 1.0 (boost is now per-app)
            appDeviceRouting = try c.decodeIfPresent([String: String].self, forKey: .appDeviceRouting) ?? [:]
            appMutes = try c.decodeIfPresent([String: Bool].self, forKey: .appMutes) ?? [:]
            appBoosts = try c.decodeIfPresent([String: Float].self, forKey: .appBoosts) ?? [:]
            appEQSettings = try c.decodeIfPresent([String: EQSettings].self, forKey: .appEQSettings) ?? [:]
            var decodedAppSettings = try c.decodeIfPresent(AppSettings.self, forKey: .appSettings) ?? AppSettings()
            if !decodedAppSettings.defaultNewAppVolume.isFinite || decodedAppSettings.defaultNewAppVolume < 0 {
                decodedAppSettings.defaultNewAppVolume = 1.0
            }

            appSettings = decodedAppSettings
            systemSoundsFollowsDefault = try c.decodeIfPresent(Bool.self, forKey: .systemSoundsFollowsDefault) ?? true
            appDeviceSelectionMode = try c.decodeIfPresent([String: DeviceSelectionMode].self, forKey: .appDeviceSelectionMode) ?? [:]
            appSelectedDeviceUIDs = try c.decodeIfPresent([String: [String]].self, forKey: .appSelectedDeviceUIDs) ?? [:]
            lockedInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .lockedInputDeviceUID)
            preferredInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .preferredInputDeviceUID)
            pinnedApps = try c.decodeIfPresent(Set<String>.self, forKey: .pinnedApps) ?? []
            pinnedAppInfo = try c.decodeIfPresent([String: PinnedAppInfo].self, forKey: .pinnedAppInfo) ?? [:]
            ignoredApps = try c.decodeIfPresent(Set<String>.self, forKey: .ignoredApps) ?? []
            ignoredAppInfo = try c.decodeIfPresent([String: IgnoredAppInfo].self, forKey: .ignoredAppInfo) ?? [:]
            ddcVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcVolumes) ?? [:]
            ddcMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .ddcMuteStates) ?? [:]
            ddcSavedVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcSavedVolumes) ?? [:]
            softwareDeviceVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            softwareDeviceMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .softwareDeviceMuteStates) ?? [:]
            softwareDeviceSavedVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceSavedVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            outputDevicePriority = try c.decodeIfPresent([String].self, forKey: .outputDevicePriority) ?? []
            inputDevicePriority = try c.decodeIfPresent([String].self, forKey: .inputDevicePriority) ?? []
            deviceAutoEQ = try c.decodeIfPresent([String: AutoEQSelection].self, forKey: .deviceAutoEQ) ?? [:]
            favoriteAutoEQProfiles = try c.decodeIfPresent(Set<String>.self, forKey: .favoriteAutoEQProfiles) ?? []
            autoEQPreampEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEQPreampEnabled) ?? true
            userEQPresets = try c.decodeIfPresent([UserEQPreset].self, forKey: .userEQPresets) ?? []
        }
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

    // MARK: - Per-App Boost

    func getBoost(for identifier: String) -> BoostLevel? {
        guard let raw = settings.appBoosts[identifier] else { return nil }
        return BoostLevel(rawValue: raw)
    }

    func setBoost(for identifier: String, to boost: BoostLevel) {
        settings.appBoosts[identifier] = boost.rawValue
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
        return settings.appEQSettings[appIdentifier] ?? EQSettings.flat
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

    var preferredInputDeviceUID: String? {
        settings.preferredInputDeviceUID
    }

    func setPreferredInputDeviceUID(_ uid: String?) {
        settings.preferredInputDeviceUID = uid
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

    // MARK: - Ignored Apps

    func ignoreApp(_ identifier: String, info: IgnoredAppInfo) {
        settings.ignoredApps.insert(identifier)
        settings.ignoredAppInfo[identifier] = info
        // Hiding is mutually exclusive with pinning
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        // Clear per-app settings — FineTune won't interact with this app
        settings.appVolumes.removeValue(forKey: identifier)
        settings.appBoosts.removeValue(forKey: identifier)
        settings.appMutes.removeValue(forKey: identifier)
        settings.appDeviceRouting.removeValue(forKey: identifier)
        settings.appEQSettings.removeValue(forKey: identifier)
        settings.appDeviceSelectionMode.removeValue(forKey: identifier)
        settings.appSelectedDeviceUIDs.removeValue(forKey: identifier)
        scheduleSave()
    }

    func unignoreApp(_ identifier: String) {
        settings.ignoredApps.remove(identifier)
        settings.ignoredAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isIgnored(_ identifier: String) -> Bool {
        settings.ignoredApps.contains(identifier)
    }

    func getIgnoredAppInfo() -> [IgnoredAppInfo] {
        settings.ignoredApps.compactMap { settings.ignoredAppInfo[$0] }
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

    // MARK: - Software Output Device Volume

    func getSoftwareDeviceVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceVolumes[deviceUID]
    }

    func setSoftwareDeviceVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceVolumes[deviceUID] = normalizedDeviceVolume(volume)
        scheduleSave()
    }

    func getSoftwareDeviceMuteState(for deviceUID: String) -> Bool {
        settings.softwareDeviceMuteStates[deviceUID] ?? false
    }

    func setSoftwareDeviceMuteState(for deviceUID: String, to muted: Bool) {
        settings.softwareDeviceMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getSoftwareDeviceSavedVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceSavedVolumes[deviceUID]
    }

    func setSoftwareDeviceSavedVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceSavedVolumes[deviceUID] = normalizedDeviceVolume(volume)
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

    /// Merges reordered connected devices into the full priority list, preserving
    /// disconnected device positions via an anchor algorithm.
    ///
    /// Each disconnected UID is anchored to the last connected UID that preceded it
    /// in `oldPriority`. When rebuilding, disconnected UIDs are inserted after their
    /// anchor (or at the start if no anchor exists).
    ///
    /// - Parameters:
    ///   - oldPriority: The full saved priority list (connected + disconnected UIDs).
    ///   - connectedOrder: The user's reordered list of currently-connected UIDs.
    /// - Returns: Merged priority list preserving disconnected positions relative to connected anchors.
    func mergeDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.outputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Input device variant of `mergeDevicePriorityOrder`.
    func mergeInputDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.inputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Pure function: merges reordered connected UIDs back into the full priority list.
    ///
    /// Algorithm:
    /// 1. Walk `oldPriority` and assign each disconnected UID an "anchor" — the last
    ///    connected UID that preceded it.  UIDs with no preceding connected UID use
    ///    `nil` anchor (inserted at the front).
    /// 2. Build result from `connectedOrder`, inserting disconnected groups after
    ///    their anchor.
    /// 3. Append any connected UIDs not in `oldPriority` at the end (brand new devices).
    static func mergePriorityOrder(oldPriority: [String], connectedOrder: [String]) -> [String] {
        let connectedSet = Set(connectedOrder)

        // Step 1: Build anchor map — disconnected UID → last connected UID before it (or nil)
        // Also collect ordering of disconnected UIDs per anchor to preserve relative order
        var anchoredGroups: [String?: [String]] = [:]  // anchor → [disconnected UIDs]
        var currentAnchor: String? = nil

        for uid in oldPriority {
            if connectedSet.contains(uid) {
                currentAnchor = uid
            } else {
                anchoredGroups[currentAnchor, default: []].append(uid)
            }
        }

        // Step 2: Build result — insert disconnected groups after their anchors
        var result: [String] = []

        // First, insert any disconnected UIDs anchored to nil (they were before all connected devices)
        if let prefixGroup = anchoredGroups[nil] {
            result.append(contentsOf: prefixGroup)
        }

        for uid in connectedOrder {
            result.append(uid)
            if let group = anchoredGroups[uid] {
                result.append(contentsOf: group)
            }
        }

        return result
    }

    /// Removes per-app settings for apps that are no longer active, not pinned,
    /// and have only default values. Preserves device routing (explicit user intent).
    ///
    /// - Parameter activeIdentifiers: Persistence identifiers of currently active apps.
    func pruneStaleSettings(keeping activeIdentifiers: Set<String>) {
        let allIdentifiers = Set(settings.appVolumes.keys)
            .union(settings.appBoosts.keys)
            .union(settings.appMutes.keys)
            .union(settings.appEQSettings.keys)
            .union(settings.appDeviceSelectionMode.keys)
            .union(settings.appSelectedDeviceUIDs.keys)

        var pruned = 0
        for identifier in allIdentifiers {
            // Keep active apps
            if activeIdentifiers.contains(identifier) { continue }
            // Keep pinned apps
            if settings.pinnedApps.contains(identifier) { continue }
            // Keep apps with explicit device routing (user intent)
            if settings.appDeviceRouting[identifier] != nil { continue }

            // Check if all remaining settings are default values
            let volume = settings.appVolumes[identifier]
            let mute = settings.appMutes[identifier]
            let eq = settings.appEQSettings[identifier]
            let selectionMode = settings.appDeviceSelectionMode[identifier]
            let selectedUIDs = settings.appSelectedDeviceUIDs[identifier]

            let boost = settings.appBoosts[identifier]

            let isDefaultVolume = volume == nil || volume == 1.0
            let isDefaultBoost = boost == nil || boost == BoostLevel.x1.rawValue
            let isDefaultMute = mute == nil || mute == false
            let isDefaultEQ = eq == nil || eq == .flat
            let isDefaultSelectionMode = selectionMode == nil
            let isDefaultSelectedUIDs = selectedUIDs == nil || selectedUIDs?.isEmpty == true

            guard isDefaultVolume && isDefaultBoost && isDefaultMute && isDefaultEQ
                    && isDefaultSelectionMode && isDefaultSelectedUIDs else {
                continue
            }

            // All values are defaults — safe to prune
            settings.appVolumes.removeValue(forKey: identifier)
            settings.appBoosts.removeValue(forKey: identifier)
            settings.appMutes.removeValue(forKey: identifier)
            settings.appEQSettings.removeValue(forKey: identifier)
            settings.appDeviceSelectionMode.removeValue(forKey: identifier)
            settings.appSelectedDeviceUIDs.removeValue(forKey: identifier)
            pruned += 1
        }

        if pruned > 0 {
            logger.info("Pruned \(pruned) stale app settings entries")
            scheduleSave()
        }
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settings.deviceAutoEQ[deviceUID]
    }

    func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?) {
        settings.deviceAutoEQ[deviceUID] = selection
        scheduleSave()
    }

    func favoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.insert(id)
        scheduleSave()
    }

    func unfavoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.remove(id)
        scheduleSave()
    }

    func isAutoEQFavorite(id: String) -> Bool {
        settings.favoriteAutoEQProfiles.contains(id)
    }

    var favoriteAutoEQProfileIDs: Set<String> {
        settings.favoriteAutoEQProfiles
    }

    var autoEQPreampEnabled: Bool {
        get { settings.autoEQPreampEnabled }
        set {
            settings.autoEQPreampEnabled = newValue
            scheduleSave()
        }
    }

    // MARK: - User EQ Presets

    /// Returns all user-created EQ presets, ordered by creation date (newest first).
    func getUserPresets() -> [UserEQPreset] {
        settings.userEQPresets.sorted { $0.createdAt > $1.createdAt }
    }

    /// Creates a new user EQ preset with the given name and band gains.
    /// Trims whitespace, falls back to "Untitled" for empty names,
    /// and auto-suffixes duplicates Finder-style: "Name (2)", "Name (3)", etc.
    /// Returns the created preset.
    @discardableResult
    func createUserPreset(name: String, settings eqSettings: EQSettings) -> UserEQPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled" : trimmed
        let finalName = uniquePresetName(baseName)
        let preset = UserEQPreset(name: finalName, settings: eqSettings)
        settings.userEQPresets.append(preset)
        scheduleSave()
        return preset
    }

    /// Renames an existing user preset. Trims whitespace; rejects empty names (no-op).
    /// Auto-suffixes if the new name collides with another preset.
    /// No-op if the preset ID is not found.
    func updateUserPreset(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = settings.userEQPresets.firstIndex(where: { $0.id == id }) else { return }
        let finalName = uniquePresetName(trimmed, excluding: id)
        settings.userEQPresets[index].name = finalName
        scheduleSave()
    }

    /// Generates a unique preset name by appending (2), (3), etc. if the name
    /// already exists among user presets. Follows Finder duplicate naming convention.
    /// - Parameters:
    ///   - name: The desired base name.
    ///   - excludeID: A preset ID to exclude from collision checks (used during rename).
    /// - Returns: A unique name, either the original or with a numeric suffix.
    private func uniquePresetName(_ name: String, excluding excludeID: UUID? = nil) -> String {
        let existingNames = Set(
            settings.userEQPresets
                .filter { $0.id != excludeID }
                .map { $0.name }
        )
        guard existingNames.contains(name) else { return name }

        var counter = 2
        while true {
            let candidate = "\(name) (\(counter))"
            if !existingNames.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// Deletes a user preset by ID. No-op if the preset ID is not found.
    func deleteUserPreset(id: UUID) {
        settings.userEQPresets.removeAll { $0.id == id }
        scheduleSave()
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
        settings.appBoosts.removeAll()
        settings.appDeviceRouting.removeAll()
        settings.appMutes.removeAll()
        settings.appEQSettings.removeAll()
        settings.pinnedApps.removeAll()
        settings.pinnedAppInfo.removeAll()
        settings.ignoredApps.removeAll()
        settings.ignoredAppInfo.removeAll()
        settings.appSettings = AppSettings()
        settings.systemSoundsFollowsDefault = true
        settings.lockedInputDeviceUID = nil
        settings.preferredInputDeviceUID = nil
        settings.ddcVolumes.removeAll()
        settings.ddcMuteStates.removeAll()
        settings.ddcSavedVolumes.removeAll()
        settings.softwareDeviceVolumes.removeAll()
        settings.softwareDeviceMuteStates.removeAll()
        settings.softwareDeviceSavedVolumes.removeAll()
        settings.outputDevicePriority.removeAll()
        settings.inputDevicePriority.removeAll()
        settings.autoEQPreampEnabled = true
        settings.deviceAutoEQ.removeAll()
        settings.favoriteAutoEQProfiles.removeAll()
        settings.appDeviceSelectionMode.removeAll()
        settings.appSelectedDeviceUIDs.removeAll()
        settings.userEQPresets.removeAll()

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

    private func normalizedDeviceVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 1.0 }
        return max(0.0, min(1.0, volume))
    }
}
