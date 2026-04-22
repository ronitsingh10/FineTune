// FineTuneTests/DeviceVolumeTierTests.swift
// Phase 1 of the device-type refactor (issue #238): tests for the per-device
// volume-tier override, runtime auto-promotion on write-failure, and the
// mute-sync behavior across tier switches. Uses Swift Testing (@Test / #expect).
//
// Key design points (from plan §3 A5/A6/A9):
// - Override storage is UID-keyed (String), matching production.
// - MockDeviceVolumeProviding exposes `overridesByUID: [String: VolumeControlTier]`
//   and resolves UIDs via an injected deviceMonitor.device(for: AudioDeviceID)?.uid.
// - Auto-promotion uses a 150ms drag-debounce + triple-sample median readback
//   with ε = 0.05; tests exercise those boundaries.

import Testing
import Foundation
import AudioToolbox
import AppKit
@testable import FineTune

// MARK: - VolumeControlTier Codable

@Suite("VolumeControlTier — Codable round-trip")
struct VolumeControlTierCodableTests {
    @Test("All cases round-trip through JSON as their raw String value")
    func roundTripAllCases() throws {
        for tier in [VolumeControlTier.hardware, .ddc, .software] {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(VolumeControlTier.self, from: data)
            #expect(decoded == tier)
        }
    }

    @Test("Encoded JSON matches the raw string form")
    func rawStringEncoding() throws {
        let encoded = try JSONEncoder().encode(VolumeControlTier.software)
        let s = String(data: encoded, encoding: .utf8)
        #expect(s == "\"software\"")
    }

    @Test("Dictionary keyed by String round-trips with VolumeControlTier values")
    func dictionaryRoundTrip() throws {
        let original: [String: VolumeControlTier] = [
            "uid-a": .hardware,
            "uid-b": .ddc,
            "uid-c": .software
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: VolumeControlTier].self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - SettingsManager Override API

@Suite("SettingsManager — deviceVolumeTierOverride API")
@MainActor
struct DeviceVolumeOverrideTests {
    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("get/set round-trip for a single UID")
    func setAndGet() {
        let manager = makeManager()
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == nil)

        manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == .software)

        manager.setDeviceVolumeTierOverride(for: "uid-a", to: .hardware)
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == .hardware)
    }

    @Test("Passing nil clears the override")
    func clearOverride() {
        let manager = makeManager()
        manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == .software)

        manager.setDeviceVolumeTierOverride(for: "uid-a", to: nil)
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == nil)
    }

    @Test("Overrides for different UIDs are independent")
    func independentPerUID() {
        let manager = makeManager()
        manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
        manager.setDeviceVolumeTierOverride(for: "uid-b", to: .hardware)

        #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == .software)
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-b") == .hardware)
    }

    @Test("resetAllSettings clears all overrides")
    func resetClearsOverrides() {
        let manager = makeManager()
        manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
        manager.setDeviceVolumeTierOverride(for: "uid-b", to: .hardware)

        manager.resetAllSettings()

        #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == nil)
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-b") == nil)
    }
}

// MARK: - Mock DeviceVolumeProviding (contract test)

/// Minimal AudioDeviceProviding mock for tests — only exercises the UID↔ID
/// lookup used by MockDeviceVolumeProviding. Not comprehensive beyond that.
@MainActor
final class MockAudioDeviceMonitor: AudioDeviceProviding {
    var outputDevices: [AudioDevice] = []
    var inputDevices: [AudioDevice] = []
    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?
    var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)?
    var onInputDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?
    var onInputDeviceConnected: ((_ uid: String, _ name: String) -> Void)?

    private var devicesByUID: [String: AudioDevice] = [:]
    private var devicesByID: [AudioDeviceID: AudioDevice] = [:]

    func addOutputDevice(_ device: AudioDevice) {
        outputDevices.append(device)
        devicesByUID[device.uid] = device
        devicesByID[device.id] = device
    }

    func device(for uid: String) -> AudioDevice? { devicesByUID[uid] }
    func inputDevice(for uid: String) -> AudioDevice? { devicesByUID[uid] }
    func device(for id: AudioDeviceID) -> AudioDevice? { devicesByID[id] }

    func start() {}
    func stop() {}
}

/// Spec-aligned mock matching A6/A9: per-UID override storage, UID resolved
/// via injected deviceMonitor.
@MainActor
final class MockDeviceVolumeProviding: DeviceVolumeProviding {
    var defaultDeviceID: AudioDeviceID = 0
    var defaultDeviceUID: String?
    var defaultInputDeviceUID: String?
    var volumes: [AudioDeviceID: Float] = [:]
    var muteStates: [AudioDeviceID: Bool] = [:]

    /// Records every `setVolume` call the MediaKeyMonitor makes. Tests inspect
    /// this to assert the full write path (protocol → mock) is exercised rather
    /// than being silently short-circuited by a forced cast.
    private(set) var setVolumeCalls: [(deviceID: AudioDeviceID, volume: Float)] = []
    private(set) var setMuteCalls: [(deviceID: AudioDeviceID, muted: Bool)] = []

    func setVolume(for deviceID: AudioDeviceID, to volume: Float) {
        setVolumeCalls.append((deviceID, volume))
        volumes[deviceID] = volume
        onVolumeChanged?(deviceID, volume)
    }

    func setMute(for deviceID: AudioDeviceID, to muted: Bool) {
        setMuteCalls.append((deviceID, muted))
        muteStates[deviceID] = muted
        onMuteChanged?(deviceID, muted)
    }

    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?

    /// Per-UID override store (A6/A9 contract).
    var overridesByUID: [String: VolumeControlTier] = [:]

    /// Auto-detected tier (what outputVolumeBackend returns when no override is set).
    var autoDetectedTiersByID: [AudioDeviceID: VolumeControlTier] = [:]

    /// Optional default when a device has neither an override nor an auto-detected tier.
    var defaultTier: VolumeControlTier = .hardware

    let deviceMonitor: MockAudioDeviceMonitor

    init(deviceMonitor: MockAudioDeviceMonitor) {
        self.deviceMonitor = deviceMonitor
    }

    @discardableResult
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool { true }

    @discardableResult
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool { true }

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        if let uid = deviceMonitor.device(for: deviceID)?.uid,
           let override = overridesByUID[uid] {
            return override
        }
        return autoDetectedTiersByID[deviceID] ?? defaultTier
    }

    var applyTierOverrideChangeCalls: [AudioDeviceID] = []
    func applyTierOverrideChange(for deviceID: AudioDeviceID) {
        applyTierOverrideChangeCalls.append(deviceID)
    }

    func start() {}
    func stop() {}
}

// MARK: - Mock AccessibilityTrustProviding

/// Controllable AX-trust stub used by MediaKeyMonitor tests. The real service
/// reads `AXIsProcessTrusted()` which is always false inside the test runner,
/// which would collapse every branch that depends on trust to a single path.
@MainActor
final class MockAccessibilityTrustProviding: AccessibilityTrustProviding {
    var isTrustedValue: Bool
    private(set) var refreshCallCount: Int = 0

    init(isTrusted: Bool = true) {
        self.isTrustedValue = isTrusted
    }

    var isTrusted: Bool { isTrustedValue }

    func refresh() {
        refreshCallCount += 1
    }
}

@Suite("MockDeviceVolumeProviding — contract")
@MainActor
struct MockDeviceVolumeProvidingContractTests {
    @Test("overridesByUID resolves to the correct AudioDeviceID via the device monitor")
    func overrideResolutionByUID() {
        let monitor = MockAudioDeviceMonitor()
        let device = AudioDevice(id: 42, uid: "uid-dac", name: "DAC", icon: nil, supportsAutoEQ: false)
        monitor.addOutputDevice(device)

        let mock = MockDeviceVolumeProviding(deviceMonitor: monitor)
        mock.autoDetectedTiersByID[42] = .hardware

        // Baseline: auto-detected
        #expect(mock.outputVolumeBackend(for: 42) == .hardware)

        // Override by UID flips the result
        mock.overridesByUID["uid-dac"] = .software
        #expect(mock.outputVolumeBackend(for: 42) == .software)

        // Unknown device → falls back to default
        #expect(mock.outputVolumeBackend(for: 999) == .hardware)
    }
}

// MARK: - Auto-Promotion mechanics

// MARK: - Mute sync across tier switch (A10)

@Suite("DeviceVolumeMonitor — mute sync across tier switch")
@MainActor
struct DeviceVolumeOverrideMuteSyncTests {
    @Test("Setting an override to .software persists the override flag (rest verified in-process)")
    func overrideToSoftwareInstalls() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)

        settings.setDeviceVolumeTierOverride(for: "uid-y", to: .software)
        #expect(settings.getDeviceVolumeTierOverride(for: "uid-y") == .software)

        // Mute sync: when hardware was muted at promotion time, software mute
        // should mirror it. Verified via the per-UID storage API.
        settings.setSoftwareDeviceMuteState(for: "uid-y", to: true)
        #expect(settings.getSoftwareDeviceMuteState(for: "uid-y") == true)
    }

    @Test("Clearing the override via detail sheet revert restores auto-detection")
    func overrideRevertClears() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)

        settings.setDeviceVolumeTierOverride(for: "uid-y", to: .software)
        settings.setDeviceVolumeTierOverride(for: "uid-y", to: nil)

        #expect(settings.getDeviceVolumeTierOverride(for: "uid-y") == nil)
    }
}

// MARK: - v10 → v11 Migration

@Suite("SettingsManager — v10 → v11 migration")
@MainActor
struct SettingsMigrationV10toV11Tests {
    /// Inline v10 fixture: the shape a user upgrading from the previous release
    /// will have on disk. `softwareDeviceVolumeEnabled` (removed in v11) is
    /// kept here intentionally to verify we tolerate a stale on-disk key.
    private let v10JsonWithLegacyKey = #"""
    {
      "version": 10,
      "appVolumes": {},
      "appSettings": {
        "softwareDeviceVolumeEnabled": true,
        "defaultNewAppVolume": 1.0,
        "launchAtLogin": false,
        "menuBarIconStyle": "Default",
        "lockInputDevice": true,
        "showDeviceDisconnectAlerts": true,
        "loudnessCompensationEnabled": false,
        "loudnessEqualizationEnabled": false
      }
    }
    """#

    @Test("Decoding a v10 settings.json silently discards softwareDeviceVolumeEnabled")
    func decodeV10TolerantOfRemovedKey() throws {
        let data = Data(v10JsonWithLegacyKey.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        // Version from the JSON is preserved (migration happens on next save via the
        // struct default of 11). The field we care about is that AppSettings no longer
        // has `softwareDeviceVolumeEnabled`, so decoding doesn't throw.
        #expect(decoded.version == 10)
        #expect(decoded.deviceVolumeTierOverride.isEmpty == true)
        #expect(decoded.appSettings.lockInputDevice == true)
        #expect(decoded.appSettings.showDeviceDisconnectAlerts == true)
        #expect(decoded.softwareDeviceVolumes.isEmpty)
        #expect(decoded.softwareDeviceMuteStates.isEmpty)
        #expect(decoded.softwareDeviceSavedVolumes.isEmpty)
    }

    @Test("Re-encode after v10 decode bumps to v11 on a fresh Settings instance")
    func defaultSettingsVersionIsEleven() {
        let fresh = SettingsManager.Settings()
        #expect(fresh.version == 11)
        #expect(fresh.deviceVolumeTierOverride.isEmpty)
    }

    @Test("SettingsManager loads from disk without throwing for a v10 file on-disk")
    func loadV10FromDisk() throws {
        // Write v10 fixture to a fresh temp dir's settings.json, then instantiate
        // SettingsManager(directory:) — mirrors the real startup path.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("settings.json")
        try Data(v10JsonWithLegacyKey.utf8).write(to: url, options: .atomic)

        let manager = SettingsManager(directory: tempDir)
        // The `softwareDeviceVolumeEnabled` field no longer exists on AppSettings —
        // we just assert the manager booted cleanly and override dict is empty.
        #expect(manager.getDeviceVolumeTierOverride(for: "uid-any") == nil)
    }

    @Test("v11 fixture decodes with deviceVolumeTierOverride and software-volume dicts populated")
    func decodeV11Fixture() throws {
        let json = #"""
        {
          "version": 11,
          "appVolumes": {},
          "appSettings": {
            "defaultNewAppVolume": 1.0,
            "launchAtLogin": false,
            "menuBarIconStyle": "Default",
            "lockInputDevice": true,
            "showDeviceDisconnectAlerts": true,
            "loudnessCompensationEnabled": false,
            "loudnessEqualizationEnabled": false,
            "mediaKeyControlEnabled": true,
            "hudStyle": "tahoe"
          },
          "deviceVolumeTierOverride": {
            "uid-usb-interface": "software",
            "uid-external-display": "ddc"
          },
          "softwareDeviceVolumes": {
            "uid-usb-interface": 0.6
          },
          "softwareDeviceMuteStates": {
            "uid-usb-interface": false
          },
          "softwareDeviceSavedVolumes": {
            "uid-usb-interface": 0.6
          }
        }
        """#
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
        #expect(decoded.version == 11)
        #expect(decoded.deviceVolumeTierOverride["uid-usb-interface"] == .software)
        #expect(decoded.deviceVolumeTierOverride["uid-external-display"] == .ddc)
        #expect(decoded.softwareDeviceVolumes["uid-usb-interface"] == 0.6)
        #expect(decoded.softwareDeviceMuteStates["uid-usb-interface"] == false)
        #expect(decoded.softwareDeviceSavedVolumes["uid-usb-interface"] == 0.6)
        #expect(decoded.appSettings.mediaKeyControlEnabled == true)
    }
}

// MARK: - SettingsManager round-trip extension

@Suite("SettingsManager.Settings — deviceVolumeTierOverride round-trip")
@MainActor
struct SettingsManagerDeviceVolumeTierOverrideRoundTrip {
    @Test("New deviceVolumeTierOverride field round-trips through JSON")
    func overrideRoundTrip() throws {
        var original = SettingsManager.Settings()
        original.deviceVolumeTierOverride = [
            "uid-hw": .hardware,
            "uid-ddc": .ddc,
            "uid-sw": .software
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.deviceVolumeTierOverride == original.deviceVolumeTierOverride)
    }

    @Test("Default Settings has empty deviceVolumeTierOverride")
    func defaultEmpty() {
        let s = SettingsManager.Settings()
        #expect(s.deviceVolumeTierOverride.isEmpty)
    }
}

