// FineTuneTests/AudioEngineResetCacheTests.swift
import Testing
import Foundation
import AppKit
@testable import FineTune

@Suite("AudioEngine.handleAudioCacheReset")
@MainActor
struct AudioEngineResetCacheTests {
    @Test("handleAudioCacheReset clears transient app volume state")
    func resetCacheClearsVolumeState() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        let engine = AudioEngine(
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: mockVolume,
            startMonitorsAutomatically: false
        )

        let app = AudioApp(
            id: 42424,
            processObjectIDs: [],
            name: "TestApp",
            icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.test.resetCache"
        )

        engine.volumeState.setVolume(for: app.id, to: 0.2, identifier: app.persistenceIdentifier)
        engine.volumeState.setBoost(for: app.id, to: .x3, identifier: app.persistenceIdentifier)

        #expect(engine.volumeState.getVolume(for: app.id) == 0.2)
        #expect(engine.volumeState.getBoost(for: app.id) == .x3)

        engine.handleAudioCacheReset()

        #expect(engine.volumeState.getVolume(for: app.id) == 1.0)
        #expect(engine.volumeState.getBoost(for: app.id) == .x1)
    }
}
