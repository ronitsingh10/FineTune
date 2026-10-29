import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

/// No CoreAudio tap, device mutation, application launch, or playback occurs here.
@Suite("AudioEngine experimental output lock")
@MainActor
struct AudioEngineOutputLockTests {
    @Test("Missing locked output is guarded at startup and for a later app")
    func startupAndNewApp() throws {
        let f = OutputLockFixture(connected: false)
        f.engine.applyPersistedSettings()
        let first = try #require(f.taps[f.app.id])
        #expect(first.persistentOutputGuardEnabled)
        #expect(first.outputBlocked)
        #expect(first.currentDeviceUID == f.lg.uid)
        #expect(f.engine.outputLockWaiting)

        let second = f.makeApp(id: 12346)
        f.processes.activeApps.append(second)
        f.processes.onAppsChanged?(f.processes.activeApps)
        let added = try #require(f.taps[second.id])
        #expect(added.persistentOutputGuardEnabled)
        #expect(added.outputBlocked)
        #expect(added.currentDeviceUID == f.lg.uid)
        #expect(!added.events.contains(.restoreGuardedOutput(f.speakers.uid)))
    }

    @Test("Disconnect and default fallback cannot be released by user mute or volume")
    func independentBlock() async throws {
        let f = OutputLockFixture()
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        f.disconnect()
        f.volume.defaultDeviceUID = f.speakers.uid
        f.volume.onDefaultDeviceChanged?(f.speakers.uid)
        f.engine.setMute(for: f.app, to: true)
        f.engine.setMute(for: f.app, to: false)
        f.engine.setVolume(for: f.app, to: 0.42)
        await settleTasks()

        #expect(tap.outputBlocked)
        #expect(!tap.isMuted)
        #expect(tap.persistentOutputGuardEnabled)
        #expect(tap.currentDeviceUID == f.lg.uid)
        #expect(f.engine.getDeviceUID(for: f.app) == f.lg.uid)
        #expect(!tap.events.contains(.invalidate))
    }

    @Test("Reconnect rebuilds the same UID and preserves user mute and volume")
    func reconnect() async throws {
        let f = OutputLockFixture()
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        f.engine.setVolume(for: f.app, to: 0.31)
        f.engine.setMute(for: f.app, to: true)
        f.disconnect()
        f.reconnect()
        await settleTasks()

        #expect(tap.events.contains(.restoreGuardedOutput(f.lg.uid)))
        #expect(!tap.outputBlocked)
        #expect(tap.isMuted)
        #expect(abs(tap.volume - 0.31) < 0.0001)
        #expect(!f.engine.outputLockWaiting)
        #expect(!tap.events.contains(.invalidate))
    }

    @Test("Failed rebuild retains source guard and silence")
    func failedRestore() async throws {
        let f = OutputLockFixture()
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        tap.guardedRestoreError = NSError(domain: "test", code: 1)
        f.disconnect()
        f.reconnect()
        await settleTasks()

        #expect(tap.outputBlocked)
        #expect(tap.persistentOutputGuardEnabled)
        #expect(f.engine.outputLockWaiting)
        #expect(!tap.events.contains(.invalidate))
    }

    @Test("A disconnect during async restore cannot clear the block")
    func disconnectDuringRestore() async throws {
        let f = OutputLockFixture()
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        tap.guardedRestoreHandler = { f.disconnect() }
        f.disconnect()
        f.reconnect()
        await settleTasks()

        #expect(tap.outputBlocked)
        #expect(f.engine.outputLockWaiting)
    }

    @Test("Initial render failure retains the guard for a later successful rebuild")
    func initialRenderFailure() async throws {
        let f = OutputLockFixture()
        f.activationError = NSError(domain: "test-render", code: 1)
        f.restoreError = NSError(domain: "test-rebuild", code: 2)
        f.engine.applyPersistedSettings()
        await settleTasks()
        let tap = try #require(f.taps[f.app.id])
        #expect(tap.persistentOutputGuardEnabled)
        #expect(tap.outputBlocked)
        #expect(tap.events.contains(.restoreGuardedOutput(f.lg.uid)))
        #expect(!tap.events.contains(.invalidate))

        tap.guardedRestoreError = nil
        f.disconnect()
        f.reconnect()
        await settleTasks()
        #expect(!tap.outputBlocked)
        #expect(f.createdTapCount == 1)
    }

    @Test("A restarted browser helper updates source protection under the same parent PID")
    func replacedAudioHelper() async throws {
        let f = OutputLockFixture()
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        let changed = AudioApp(id: f.app.id, processObjectIDs: [42], name: f.app.name, icon: NSImage(), bundleID: f.app.bundleID)
        f.processes.activeApps = [changed]
        f.processes.onAppsChanged?([changed])
        #expect(tap.outputBlocked)
        await settleTasks()

        #expect(tap.app.processObjectIDs == [42])
        #expect(tap.events.contains(.updateGuardedApp([42])))
        #expect(tap.events.contains(.restoreGuardedOutput(f.lg.uid)))
        #expect(!tap.outputBlocked)
        #expect(tap.persistentOutputGuardEnabled)
        #expect(f.createdTapCount == 1)
    }

    @Test("Explicit unrelated output stays outside the lock")
    func unrelatedOutput() throws {
        let f = OutputLockFixture(connected: false)
        f.settings.setDeviceRouting(for: f.app.persistenceIdentifier, deviceUID: f.speakers.uid)
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        #expect(!tap.persistentOutputGuardEnabled)
        #expect(!tap.outputBlocked)
        #expect(tap.currentDeviceUID == f.speakers.uid)
    }

    @Test("Manual default selection moves the lock and rebuilds managed output")
    func manualDefaultSelection() async throws {
        let f = OutputLockFixture()
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        #expect(f.engine.setDefaultOutputDevice(f.speakers.id))
        await settleTasks()

        #expect(f.settings.appSettings.lockedOutputDeviceUID == f.speakers.uid)
        #expect(tap.currentDeviceUID == f.speakers.uid)
        #expect(!tap.outputBlocked)
        #expect(tap.persistentOutputGuardEnabled)
    }

    @Test("Enabling captures current default; disabling releases a waiting guard")
    func enableAndDisable() async throws {
        let f = OutputLockFixture(lockEnabled: false)
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        #expect(!tap.persistentOutputGuardEnabled)
        f.engine.setOutputDeviceLockEnabled(true)
        await settleTasks()
        #expect(f.settings.appSettings.lockedOutputDeviceUID == f.lg.uid)
        #expect(tap.persistentOutputGuardEnabled)
        f.disconnect()
        f.volume.defaultDeviceUID = f.speakers.uid
        f.engine.setOutputDeviceLockEnabled(false)
        await settleTasks()

        #expect(f.settings.appSettings.lockedOutputDeviceUID == nil)
        #expect(!tap.persistentOutputGuardEnabled)
        #expect(!tap.outputBlocked)
        #expect(tap.currentDeviceUID == f.speakers.uid)
    }

    @Test("Guard installation failure is visible and does not claim protection")
    func guardInstallationError() throws {
        let f = OutputLockFixture(lockEnabled: false)
        f.engine.applyPersistedSettings()
        let tap = try #require(f.taps[f.app.id])
        tap.guardedInstallError = NSError(domain: "test-source-guard", code: 1)
        f.engine.setOutputDeviceLockEnabled(true)
        #expect(f.engine.outputLockError != nil)
        #expect(f.engine.outputLockWaiting)
        #expect(!tap.persistentOutputGuardEnabled)

        f.engine.setOutputDeviceLockEnabled(false)
        #expect(f.engine.outputLockError == nil)
        #expect(!tap.outputBlocked)
    }

    private func settleTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class OutputLockFixture {
    let settings: SettingsManager
    let devices = MockAudioDeviceMonitor()
    let processes = StubProcessMonitor()
    let volume: MockDeviceVolumeProviding
    let lg = AudioDevice(id: 91, uid: "lg-test", name: "LG", icon: nil, supportsAutoEQ: false)
    let speakers = AudioDevice(id: 92, uid: "speakers-test", name: "Speakers", icon: nil, supportsAutoEQ: false)
    let app: AudioApp
    var engine: AudioEngine!
    var taps: [pid_t: RecordingProcessTapController] = [:]
    var activationError: Error?
    var restoreError: Error?
    var createdTapCount = 0

    init(connected: Bool = true, lockEnabled: Bool = true) {
        settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        volume = MockDeviceVolumeProviding(deviceMonitor: devices)
        app = AudioApp(id: 12345, processObjectIDs: [], name: "Test App", icon: NSImage(), bundleID: "com.test.output-lock.12345")
        devices.addOutputDevice(speakers)
        if connected { devices.addOutputDevice(lg) }
        volume.defaultDeviceUID = connected ? lg.uid : speakers.uid
        volume.defaultDeviceID = connected ? lg.id : speakers.id
        var appSettings = settings.appSettings
        appSettings.lockedOutputDeviceUID = lockEnabled ? lg.uid : nil
        appSettings.showDeviceDisconnectAlerts = false
        settings.updateAppSettings(appSettings)
        processes.activeApps = [app]
        let permission = AudioRecordingPermission()
        permission.status = .authorized
        let devices = self.devices
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: devices,
            processMonitor: processes,
            deviceVolumeMonitor: volume,
            tapFactory: { [weak self] app, uids, _ in
                let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
                tap.activationError = self?.activationError
                tap.guardedRestoreError = self?.restoreError
                self?.createdTapCount += 1
                self?.taps[app.id] = tap
                return tap
            },
            isAlive: { id in devices.outputDevices.contains { $0.id == id } },
            startMonitorsAutomatically: false
        )
    }

    func makeApp(id: pid_t) -> AudioApp {
        AudioApp(id: id, processObjectIDs: [], name: "New App", icon: NSImage(), bundleID: "com.test.output-lock.\(id)")
    }

    func disconnect() {
        devices.outputDevices.removeAll { $0.uid == lg.uid }
        devices.onDeviceDisconnected?(lg.uid, lg.name)
    }

    func reconnect() {
        devices.addOutputDevice(lg)
        devices.onDeviceConnected?(lg.uid, lg.name)
    }
}
