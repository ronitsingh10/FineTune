// FineTuneTests/SettingsManagerTests.swift
// Tests for SettingsManager.Settings JSON round-trip, merge algorithm, and pruning.
// Uses temp directories — no real settings files affected.

import Testing
import Foundation
@testable import FineTune

// MARK: - Settings JSON Round-Trip

@Suite("SettingsManager.Settings — JSON serialization")
@MainActor
struct SettingsJSONTests {

    @Test("Default Settings encodes and decodes to equal value")
    func defaultRoundTrip() throws {
        let original = SettingsManager.Settings()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == original.version)
        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.systemSoundsFollowsDefault == original.systemSoundsFollowsDefault)
    }

    @Test("Populated Settings round-trips all fields")
    func populatedRoundTrip() throws {
        var original = SettingsManager.Settings()
        original.appVolumes = ["com.test.app": 0.5]
        original.appMutes = ["com.test.app": true]
        original.appBoosts = ["com.test.app": 2.0]
        original.appDeviceRouting = ["com.test.app": "device-uid-123"]
        original.pinnedApps = Set(["com.test.app"])
        original.outputDevicePriority = ["uid-a", "uid-b", "uid-c"]
        original.ddcVolumes = ["monitor-1": 75]
        original.ddcMuteStates = ["monitor-1": false]
        original.autoEQPreampEnabled = false
        original.appSettings.autoSwitchToConnectedOutputDevice = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.appBoosts == original.appBoosts)
        #expect(decoded.appDeviceRouting == original.appDeviceRouting)
        #expect(decoded.pinnedApps == original.pinnedApps)
        #expect(decoded.outputDevicePriority == original.outputDevicePriority)
        #expect(decoded.ddcVolumes == original.ddcVolumes)
        #expect(decoded.ddcMuteStates == original.ddcMuteStates)
        #expect(decoded.autoEQPreampEnabled == false)
        #expect(decoded.appSettings.autoSwitchToConnectedOutputDevice == true)
    }

    @Test("Decoding empty JSON produces valid defaults")
    func emptyJSONDefaults() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 9)
        #expect(decoded.appVolumes.isEmpty)
        #expect(decoded.appMutes.isEmpty)
        #expect(decoded.systemSoundsFollowsDefault == true)
        #expect(decoded.autoEQPreampEnabled == true)
    }

    @Test("Decoding with extra unknown keys is tolerated")
    func unknownKeysIgnored() throws {
        let json = """
        {"version": 9, "unknownField": "hello", "anotherNew": 42}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 9)
    }

    @Test("Volume values above 1.0 are clamped to 1.0 on decode")
    func volumeClampedAboveOne() throws {
        let json = """
        {"appVolumes": {"com.test.app": 1.5, "com.other.app": 0.8}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == 1.0)
        #expect(decoded.appVolumes["com.other.app"] == 0.8)
    }

    @Test("Negative volume values are filtered out on decode")
    func negativeVolumesFiltered() throws {
        let json = """
        {"appVolumes": {"com.test.app": -0.5, "com.good.app": 0.7}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == nil, "Negative volume should be filtered out")
        #expect(decoded.appVolumes["com.good.app"] == 0.7)
    }

    @Test("Non-finite volume values cannot be encoded to JSON")
    func nonFiniteVolumesCannotEncode() throws {
        // JSON spec does not support NaN or Infinity.
        // JSONEncoder throws when encountering non-finite floats.
        // This verifies the boundary: production code's filter on decode handles
        // finite-but-invalid values (negative, >1.0); non-finite values are
        // prevented at the encoding layer.
        var settings = SettingsManager.Settings()
        settings.appVolumes["inf_app"] = Float.infinity

        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(settings)
        }
    }

    @Test("Invalid defaultNewAppVolume is reset to 1.0 on decode")
    func invalidDefaultVolumeReset() throws {
        // AppSettings uses auto-synthesized Codable — all keys required.
        // MenuBarIconStyle raw value is capitalized ("Default", not "default").
        let json = """
        {"appSettings": {"launchAtLogin": false, "menuBarIconStyle": "Default", "defaultNewAppVolume": -5.0, "lockInputDevice": true, "showDeviceDisconnectAlerts": true}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appSettings.defaultNewAppVolume == 1.0,
                "Negative defaultNewAppVolume should be reset to 1.0")
    }
}

// MARK: - mergePriorityOrder

@Suite("SettingsManager — mergePriorityOrder algorithm")
@MainActor
struct MergePriorityOrderTests {

    @Test("No disconnected devices: returns connectedOrder as-is")
    func noDisconnected() {
        let old = ["A", "B", "C"]
        let connected = ["C", "A", "B"] // user reordered
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["C", "A", "B"])
    }

    @Test("Disconnected device anchored between two connected devices")
    func disconnectedBetween() {
        let old = ["A", "D", "B"] // D is disconnected (not in connectedOrder)
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D was after A in old, so anchored to A. Result: A, D, B
        #expect(result == ["A", "D", "B"])
    }

    @Test("Disconnected device at the beginning (no preceding connected device)")
    func disconnectedAtStart() {
        let old = ["D", "A", "B"] // D is disconnected, before all connected
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D has nil anchor → inserted at front
        #expect(result == ["D", "A", "B"])
    }

    @Test("Multiple disconnected devices with same anchor")
    func multipleDisconnectedSameAnchor() {
        let old = ["A", "D1", "D2", "B"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["A", "D1", "D2", "B"])
    }

    @Test("All devices disconnected: returns disconnected in old order")
    func allDisconnected() {
        let old = ["A", "B", "C"]
        let connected: [String] = []
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // All disconnected, anchored to nil → inserted at front in order
        #expect(result == ["A", "B", "C"])
    }

    @Test("Empty old priority: returns connectedOrder")
    func emptyOldPriority() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: ["X", "Y"])
        #expect(result == ["X", "Y"])
    }

    @Test("Both empty: returns empty")
    func bothEmpty() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: [])
        #expect(result.isEmpty)
    }

    @Test("Reordering connected devices preserves disconnected anchors")
    func reorderPreservesAnchors() {
        let old = ["A", "D1", "B", "D2", "C"]
        let connected = ["C", "A", "B"] // user moved C to front
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D1 anchored to A, D2 anchored to B
        // Result: C, A, D1, B, D2
        #expect(result == ["C", "A", "D1", "B", "D2"])
    }

    @Test("Disconnected device at end (anchored to last connected)")
    func disconnectedAtEnd() {
        let old = ["A", "B", "D"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D anchored to B → after B
        #expect(result == ["A", "B", "D"])
    }
}

// MARK: - AppSettings Defaults

@Suite("AppSettings — Default values")
struct AppSettingsDefaultTests {

    @Test("Default AppSettings has expected values")
    func defaults() {
        let settings = AppSettings()
        #expect(settings.launchAtLogin == false)
        #expect(settings.menuBarIconStyle == .default)
        #expect(settings.defaultNewAppVolume == 1.0)
        #expect(settings.autoSwitchToConnectedOutputDevice == false)
        #expect(settings.lockInputDevice == true)
        #expect(settings.showDeviceDisconnectAlerts == true)
    }

    @Test("autoSwitchToConnectedOutputDevice round-trips through JSON as true")
    func autoSwitchToConnectedOutputDeviceRoundTrip() throws {
        var settings = AppSettings()
        settings.autoSwitchToConnectedOutputDevice = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.autoSwitchToConnectedOutputDevice == true)
    }

    @Test("loudnessEqualizationEnabled defaults to false")
    func loudnessEqualizationEnabledDefault() {
        let settings = AppSettings()
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled round-trips through JSON as true")
    func loudnessEqualizationEnabledRoundTrip() throws {
        var settings = AppSettings()
        settings.loudnessEqualizationEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.loudnessEqualizationEnabled == true)
    }

    @Test("Unified loudness toggle updates compensation and equalization together")
    func unifiedLoudnessToggleSetsBothFlags() {
        var settings = AppSettings()

        settings.setUnifiedLoudnessEnabled(true)
        #expect(settings.loudnessCompensationEnabled == true)
        #expect(settings.loudnessEqualizationEnabled == true)

        settings.setUnifiedLoudnessEnabled(false)
        #expect(settings.loudnessCompensationEnabled == false)
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled persists via SettingsManager")
    @MainActor
    func loudnessEqualizationEnabledPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let manager = SettingsManager(directory: tempDir)
        var newSettings = manager.appSettings
        newSettings.loudnessEqualizationEnabled = true
        manager.updateAppSettings(newSettings)
        #expect(manager.appSettings.loudnessEqualizationEnabled == true)
    }

}

// MARK: - MenuBarIconStyle

@Suite("MenuBarIconStyle — Enumeration")
struct MenuBarIconStyleTests {

    @Test("allCases has 4 styles")
    func allCasesCount() {
        #expect(MenuBarIconStyle.allCases.count == 4)
    }

    @Test("Only 'default' is not a system symbol")
    func defaultNotSystemSymbol() {
        #expect(!MenuBarIconStyle.default.isSystemSymbol)
        #expect(MenuBarIconStyle.speaker.isSystemSymbol)
        #expect(MenuBarIconStyle.waveform.isSystemSymbol)
        #expect(MenuBarIconStyle.equalizer.isSystemSymbol)
    }

    @Test("Every style has a non-empty icon name")
    func allHaveIconNames() {
        for style in MenuBarIconStyle.allCases {
            #expect(!style.iconName.isEmpty, "Style \(style.rawValue) has empty icon name")
        }
    }

    @Test("Round-trip through JSON Codable")
    func codableRoundTrip() throws {
        for style in MenuBarIconStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MenuBarIconStyle.self, from: data)
            #expect(decoded == style)
        }
    }
}
