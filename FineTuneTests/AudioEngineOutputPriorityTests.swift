import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@Suite("AudioEngine — native output switching and opt-in priority")
@MainActor
struct AudioEngineOutputPriorityTests {
    @Test("Native AirPods switching follows either HAL callback order",
          arguments: [true, false], [true, false])
    func nativeConnection(defaultCallbackFirst: Bool, airPodsRankFirst: Bool) async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        if airPodsRankFirst {
            f.settings.setDevicePriorityOrder([
                OutputPriorityFixture.airPods.uid, OutputPriorityFixture.speaker.uid
            ])
        }

        if defaultCallbackFirst {
            // HAL can report a new default before AudioDeviceMonitor knows its UID.
            f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
            #expect(f.devices.device(for: OutputPriorityFixture.airPods.uid) == nil)
            f.devices.connect(OutputPriorityFixture.airPods)
        } else {
            f.devices.connect(OutputPriorityFixture.airPods)
            #expect(f.volume.defaultWrites.isEmpty)
            f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        }

        try await f.expectRoute(to: OutputPriorityFixture.airPods)
        #expect(f.volume.defaultDeviceUID == OutputPriorityFixture.airPods.uid)
        #expect(f.volume.defaultWrites.isEmpty)
        #expect(f.engine.pendingAliveWatcherCount == 0)
    }

    @Test("Native routing waits for an announced output to become alive",
          arguments: [true, false])
    func nativeConnectionBecomesReady(defaultCallbackFirst: Bool) async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.unavailableDeviceIDs.insert(OutputPriorityFixture.airPods.id)
        if defaultCallbackFirst {
            f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
            f.devices.connect(OutputPriorityFixture.airPods)
        } else {
            f.devices.connect(OutputPriorityFixture.airPods)
            f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        }
        let tap = try #require(f.taps.byPID[f.app.id])
        #expect(tap.currentDeviceUID == OutputPriorityFixture.speaker.uid)
        #expect(tap.switchCalls.isEmpty)
        #expect(f.volume.defaultWrites.isEmpty)

        // Stand in for the HAL alive listener retry; the default does not change again.
        f.devices.unavailableDeviceIDs.remove(OutputPriorityFixture.airPods.id)
        f.devices.onDeviceConnected?(OutputPriorityFixture.airPods.uid, OutputPriorityFixture.airPods.name)
        try await f.expectRoute(to: OutputPriorityFixture.airPods)
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Native disconnect honors macOS fallback with either callback order and a missing app",
          arguments: [true, false], [true, false])
    func nativeDisconnect(defaultCallbackFirst: Bool, appTemporarilyMissing: Bool) async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.dock)
        f.devices.connect(OutputPriorityFixture.airPods)
        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await f.expectRoute(to: OutputPriorityFixture.airPods)
        if appTemporarilyMissing { f.processes.activeApps = [] }

        // macOS chooses the dock, even though speakers rank first in FineTune's list.
        if defaultCallbackFirst {
            f.volume.emitDefaultChange(OutputPriorityFixture.dock)
            f.devices.disconnect(OutputPriorityFixture.airPods)
        } else {
            // The cache still points to the removed device until the next HAL event.
            f.devices.disconnect(OutputPriorityFixture.airPods)
            #expect(f.volume.defaultWrites.isEmpty)
            #expect(f.engine.getDeviceUID(for: f.app) != OutputPriorityFixture.speaker.uid)
            f.volume.emitDefaultChange(OutputPriorityFixture.dock)
        }
        try await f.expectRoute(to: OutputPriorityFixture.dock)
        let tap = try #require(f.taps.byPID[f.app.id])
        #expect(tap.switchCalls.last?.sourceDeviceDead == true)
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Explicit app pins survive native switching and reconnect")
    func explicitPinIsPreserved() async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.engine.setDevice(for: f.pinnedApp, deviceUID: OutputPriorityFixture.speaker.uid)
        let pinnedTap = try #require(f.taps.byPID[f.pinnedApp.id])

        f.devices.connect(OutputPriorityFixture.airPods)
        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await f.expectRoute(to: OutputPriorityFixture.airPods)
        #expect(pinnedTap.currentDeviceUID == OutputPriorityFixture.speaker.uid)
        #expect(!f.engine.isFollowingDefault(for: f.pinnedApp))

        f.devices.disconnect(OutputPriorityFixture.speaker)
        try await f.expectRoute(to: OutputPriorityFixture.airPods, app: f.pinnedApp)
        #expect(f.settings.getDeviceRouting(for: f.pinnedApp.persistenceIdentifier)
                == OutputPriorityFixture.speaker.uid)

        f.devices.connect(OutputPriorityFixture.speaker)
        try await f.expectRoute(to: OutputPriorityFixture.speaker, app: f.pinnedApp)
        #expect(!f.engine.isFollowingDefault(for: f.pinnedApp))
        #expect(f.volume.defaultDeviceUID == OutputPriorityFixture.airPods.uid)
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Enabled priority restores a lower-ranked automatic switch")
    func enabledPriorityRestoresPreviousOutput() async throws {
        let f = OutputPriorityFixture(priorityEnabled: true)
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)

        #expect(f.volume.defaultWrites == [OutputPriorityFixture.speaker.id])
        #expect(f.volume.defaultDeviceUID == OutputPriorityFixture.speaker.uid)
        // Deliver the write's notification after setDefaultDevice has returned.
        f.volume.deliverCurrentDefaultNotification()
        try await f.expectRoute(to: OutputPriorityFixture.speaker)
    }

    @Test("Enabled priority selects a newly connected highest-ranked device")
    func enabledPrioritySelectsNewHighestOutput() async throws {
        let f = OutputPriorityFixture(priorityEnabled: true)
        defer { f.engine.shutdown() }
        f.settings.setDevicePriorityOrder([
            OutputPriorityFixture.airPods.uid, OutputPriorityFixture.speaker.uid
        ])
        f.devices.connect(OutputPriorityFixture.airPods)

        #expect(f.volume.defaultWrites == [OutputPriorityFixture.airPods.id])
        f.volume.deliverCurrentDefaultNotification()
        try await f.expectRoute(to: OutputPriorityFixture.airPods)
    }

    @Test("Enabling priority immediately applies the saved order")
    func enablingPriorityAppliesImmediately() async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await f.expectRoute(to: OutputPriorityFixture.airPods)

        f.setPriorityEnabled(true)

        #expect(f.volume.defaultWrites == [OutputPriorityFixture.speaker.id])
        f.volume.deliverCurrentDefaultNotification()
        try await f.expectRoute(to: OutputPriorityFixture.speaker)
    }

    @Test("Disabling priority releases a pending override and unacknowledged echo")
    func disablingPriorityReleasesPendingState() async throws {
        let f = OutputPriorityFixture(priorityEnabled: true)
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        #expect(f.volume.defaultWrites == [OutputPriorityFixture.speaker.id])
        // Deliberately leave the programmatic speaker-write notification pending.
        f.setPriorityEnabled(false)

        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await f.expectRoute(to: OutputPriorityFixture.airPods)
        #expect(f.volume.defaultWrites == [OutputPriorityFixture.speaker.id])

        // Outlive both the 2-second echo deadline and the wired grace task.
        try await Task.sleep(for: .milliseconds(2200))
        #expect(f.volume.defaultDeviceUID == OutputPriorityFixture.airPods.uid)
        try await f.expectRoute(to: OutputPriorityFixture.airPods)
        #expect(f.volume.defaultWrites == [OutputPriorityFixture.speaker.id])

        // This UID also has the old echo: it must now be accepted as a native change.
        f.volume.emitDefaultChange(OutputPriorityFixture.speaker)
        try await f.expectRoute(to: OutputPriorityFixture.speaker)
        #expect(f.volume.defaultWrites == [OutputPriorityFixture.speaker.id])
    }

    @Test("Manual output selection works with priority disabled")
    func manualOutputSelection() async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)

        #expect(f.engine.setDefaultOutputDevice(OutputPriorityFixture.airPods.id))
        #expect(f.volume.defaultWrites == [OutputPriorityFixture.airPods.id])
        f.volume.deliverCurrentDefaultNotification()
        try await f.expectRoute(to: OutputPriorityFixture.airPods)

        f.volume.emitDefaultChange(OutputPriorityFixture.speaker)
        try await f.expectRoute(to: OutputPriorityFixture.speaker)
        #expect(f.volume.defaultWrites == [OutputPriorityFixture.airPods.id])
    }

    @Test("Queued native routing respects a newer default or explicit app pin",
          arguments: [true, false])
    func queuedNativeRouteRespectsNewerSelection(pinAfterCallback: Bool) async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.devices.connect(OutputPriorityFixture.dock)
        let tap = try #require(f.taps.byPID[f.app.id])
        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)

        // Change the destination before the queued AirPods tap switch can run.
        let target = pinAfterCallback ? OutputPriorityFixture.speaker : OutputPriorityFixture.dock
        if pinAfterCallback {
            f.engine.setDevice(for: f.app, deviceUID: target.uid)
        } else {
            f.volume.emitDefaultChange(target)
        }
        // The speaker is already active in the pin case, so no switch is necessary.
        if pinAfterCallback { try await Task.sleep(for: .milliseconds(10)) }
        try await f.expectRoute(to: target)
        #expect(tap.switchCalls.allSatisfy { $0.deviceUID == target.uid })
        #expect(f.engine.isFollowingDefault(for: f.app) == !pinAfterCallback)
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Queued disconnect fallback respects a newer app pin or multi-device selection",
          arguments: [true, false])
    func queuedDisconnectFallbackRespectsNewSelection(useMulti: Bool) async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.devices.connect(OutputPriorityFixture.dock)
        f.engine.setDevice(for: f.app, deviceUID: OutputPriorityFixture.airPods.uid)
        try await f.expectRoute(to: OutputPriorityFixture.airPods)
        let tap = try #require(f.taps.byPID[f.app.id])
        let previousSwitchCount = tap.switchCalls.count

        // Disconnect queues speaker fallback; a new explicit selection supersedes it.
        f.devices.disconnect(OutputPriorityFixture.airPods)
        if useMulti {
            let targets: Set<String> = [OutputPriorityFixture.dock.uid, OutputPriorityFixture.speaker.uid]
            f.engine.setSelectedDeviceUIDs(for: f.app, to: targets)
            f.engine.setDeviceSelectionMode(for: f.app, to: .multi)
            try await f.expectDevices(targets.sorted())
            #expect(tap.switchCalls.count == previousSwitchCount)
        } else {
            f.engine.setDevice(for: f.app, deviceUID: OutputPriorityFixture.dock.uid)
            try await f.expectRoute(to: OutputPriorityFixture.dock)
            #expect(tap.switchCalls.dropFirst(previousSwitchCount).map(\.deviceUID)
                    == [OutputPriorityFixture.dock.uid])
            #expect(!f.engine.isFollowingDefault(for: f.app))
        }
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Queued multi-device disconnect respects a newer selection or single-device mode",
          arguments: [true, false])
    func queuedMultiDisconnectRespectsNewSelection(switchToSingle: Bool) async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.devices.connect(OutputPriorityFixture.dock)
        f.engine.setDevice(for: f.app, deviceUID: OutputPriorityFixture.speaker.uid)
        f.engine.setSelectedDeviceUIDs(for: f.app, to: [
            OutputPriorityFixture.speaker.uid, OutputPriorityFixture.airPods.uid
        ])
        f.engine.setDeviceSelectionMode(for: f.app, to: .multi)
        try await f.expectDevices([OutputPriorityFixture.speaker.uid, OutputPriorityFixture.airPods.uid].sorted())
        let tap = try #require(f.taps.byPID[f.app.id])
        let previousUpdateCount = tap.updateDevicesCalls.count

        // Disconnect queues [AirPods]; a new selection supersedes it before it runs.
        f.devices.disconnect(OutputPriorityFixture.speaker)
        if switchToSingle {
            f.engine.setDeviceSelectionMode(for: f.app, to: .single)
            f.engine.setDevice(for: f.app, deviceUID: OutputPriorityFixture.dock.uid)
        } else {
            f.engine.setSelectedDeviceUIDs(for: f.app, to: [OutputPriorityFixture.dock.uid])
        }
        try await f.expectDevices([OutputPriorityFixture.dock.uid])
        let newUpdates = tap.updateDevicesCalls.dropFirst(previousUpdateCount)
        #expect(newUpdates.allSatisfy { $0.deviceUIDs == [OutputPriorityFixture.dock.uid] })
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Rapid multi-device disconnects only retain outputs still connected")
    func rapidMultiDeviceDisconnects() async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.devices.connect(OutputPriorityFixture.dock)
        f.engine.setDevice(for: f.app, deviceUID: OutputPriorityFixture.speaker.uid)
        let initialUIDs: Set<String> = [
            OutputPriorityFixture.speaker.uid,
            OutputPriorityFixture.airPods.uid,
            OutputPriorityFixture.dock.uid
        ]
        f.engine.setSelectedDeviceUIDs(for: f.app, to: initialUIDs)
        f.engine.setDeviceSelectionMode(for: f.app, to: .multi)
        try await f.expectDevices(initialUIDs.sorted())
        let tap = try #require(f.taps.byPID[f.app.id])
        let previousUpdateCount = tap.updateDevicesCalls.count

        // Both callbacks arrive before either queued aggregate update can run.
        f.devices.disconnect(OutputPriorityFixture.speaker)
        f.devices.disconnect(OutputPriorityFixture.airPods)
        try await f.expectDevices([OutputPriorityFixture.dock.uid])

        #expect(f.engine.getSelectedDeviceUIDs(for: f.app) == [OutputPriorityFixture.dock.uid])
        #expect(tap.updateDevicesCalls.dropFirst(previousUpdateCount).map(\.deviceUIDs)
                == [[OutputPriorityFixture.dock.uid]])
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Native default switching preserves an active multi-device selection")
    func nativeSwitchPreservesMultiDeviceSelection() async throws {
        let f = OutputPriorityFixture()
        defer { f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.dock)
        let targets: Set<String> = [OutputPriorityFixture.speaker.uid, OutputPriorityFixture.dock.uid]
        // Start from System Audio; entering multi mode must protect its selected outputs.
        f.engine.setSelectedDeviceUIDs(for: f.app, to: targets)
        f.engine.setDeviceSelectionMode(for: f.app, to: .multi)
        try await f.expectDevices(targets.sorted())
        let tap = try #require(f.taps.byPID[f.app.id])

        f.devices.connect(OutputPriorityFixture.airPods)
        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await Task.sleep(for: .milliseconds(10))

        #expect(tap.currentDeviceUIDs == targets.sorted())
        #expect(f.engine.getSelectedDeviceUIDs(for: f.app) == targets)
        #expect(tap.switchCalls.isEmpty)
        #expect(f.volume.defaultDeviceUID == OutputPriorityFixture.airPods.uid)
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("In-flight native switch serializes and coalesces newer defaults",
          arguments: [true, false])
    func inFlightNativeSwitchFollowsLatestDefault(includeIntermediateTarget: Bool) async throws {
        let f = OutputPriorityFixture()
        let gate = OutputPrioritySwitchGate()
        defer { gate.release(); f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.devices.connect(OutputPriorityFixture.dock)
        let tap = try #require(f.taps.byPID[f.app.id])
        tap.beforeSwitch = { uid in
            if uid == OutputPriorityFixture.airPods.uid { await gate.wait() }
        }

        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await gate.expectEntered()
        if includeIntermediateTarget { f.volume.emitDefaultChange(OutputPriorityFixture.dock) }
        f.volume.emitDefaultChange(OutputPriorityFixture.speaker)
        try await Task.sleep(for: .milliseconds(10))
        #expect(tap.switchCalls.map(\.deviceUID) == [OutputPriorityFixture.airPods.uid])

        gate.release()
        try await f.expectCompletedSwitches([OutputPriorityFixture.airPods.uid, OutputPriorityFixture.speaker.uid])
        #expect(tap.maxConcurrentSwitchCount == 1)
        #expect(f.engine.isFollowingDefault(for: f.app))
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("An app pin made during an awaited native switch is applied last")
    func inFlightNativeSwitchRespectsNewPin() async throws {
        let f = OutputPriorityFixture()
        let gate = OutputPrioritySwitchGate()
        defer { gate.release(); f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.devices.connect(OutputPriorityFixture.dock)
        let tap = try #require(f.taps.byPID[f.app.id])
        tap.beforeSwitch = { uid in
            if uid == OutputPriorityFixture.airPods.uid { await gate.wait() }
        }

        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await gate.expectEntered()
        f.engine.setDevice(for: f.app, deviceUID: OutputPriorityFixture.dock.uid)
        try await Task.sleep(for: .milliseconds(10))
        #expect(tap.switchCalls.map(\.deviceUID) == [OutputPriorityFixture.airPods.uid])

        gate.release()
        try await f.expectCompletedSwitches([OutputPriorityFixture.airPods.uid, OutputPriorityFixture.dock.uid])
        #expect(tap.maxConcurrentSwitchCount == 1)
        #expect(!f.engine.isFollowingDefault(for: f.app))
        #expect(f.settings.getDeviceRouting(for: f.app.persistenceIdentifier) == OutputPriorityFixture.dock.uid)
        #expect(f.volume.defaultWrites.isEmpty)
    }

    @Test("Entering multi mode waits for an in-flight native switch to finish")
    func inFlightNativeSwitchRespectsMultiSelection() async throws {
        let f = OutputPriorityFixture()
        let gate = OutputPrioritySwitchGate()
        defer { gate.release(); f.engine.shutdown() }
        f.devices.connect(OutputPriorityFixture.airPods)
        f.devices.connect(OutputPriorityFixture.dock)
        let tap = try #require(f.taps.byPID[f.app.id])
        tap.beforeSwitch = { uid in
            if uid == OutputPriorityFixture.airPods.uid { await gate.wait() }
        }

        f.volume.emitDefaultChange(OutputPriorityFixture.airPods)
        try await gate.expectEntered()
        let targets: Set<String> = [OutputPriorityFixture.speaker.uid, OutputPriorityFixture.dock.uid]
        f.engine.setSelectedDeviceUIDs(for: f.app, to: targets)
        f.engine.setDeviceSelectionMode(for: f.app, to: .multi)
        try await Task.sleep(for: .milliseconds(10))
        #expect(tap.updateDevicesCalls.isEmpty)

        gate.release()
        // Observe completion of B, not its transient current UID; a multi update may
        // run immediately afterward and must remain the final output configuration.
        let deadline = ContinuousClock.now + .seconds(1)
        while tap.completedSwitchCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(tap.completedSwitchCount == 1)
        try await f.expectDevices(targets.sorted())
        #expect(tap.updateDevicesCalls.map(\.deviceUIDs) == [targets.sorted()])
        #expect(f.engine.getSelectedDeviceUIDs(for: f.app) == targets)
        #expect(f.volume.defaultWrites.isEmpty)
    }
}

@MainActor
private final class OutputPrioritySwitchGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    func expectEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(entered)
    }
}

@MainActor
private final class OutputPriorityFixture {
    static let speaker = AudioDevice(id: 101, uid: "test-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    static let airPods = AudioDevice(id: 102, uid: "test-airpods", name: "AirPods", icon: nil, supportsAutoEQ: false)
    static let dock = AudioDevice(id: 103, uid: "test-dock", name: "Dock", icon: nil, supportsAutoEQ: false)

    let settings: SettingsManager
    let devices: OutputPriorityDeviceMonitor
    let volume: OutputPriorityVolumeMonitor
    let processes: StubProcessMonitor
    let engine: AudioEngine
    let taps: OutputPriorityTapStore
    let app: AudioApp
    let pinnedApp: AudioApp

    init(priorityEnabled: Bool = false) {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        var options = settings.appSettings
        options.outputDevicePriorityEnabled = priorityEnabled
        options.showDeviceDisconnectAlerts = false
        options.lockInputDevice = false
        settings.updateAppSettings(options)
        settings.setDevicePriorityOrder([Self.speaker.uid, Self.airPods.uid, Self.dock.uid])
        self.settings = settings

        let devices = OutputPriorityDeviceMonitor()
        devices.outputDevices = [Self.speaker]
        self.devices = devices
        let volume = OutputPriorityVolumeMonitor(devices: devices, initialDefault: Self.speaker)
        self.volume = volume
        let app = AudioApp(id: 51001, processObjectIDs: [], name: "Following App", icon: NSImage(), bundleID: "test.output.following")
        let pinnedApp = AudioApp(id: 51002, processObjectIDs: [], name: "Pinned App", icon: NSImage(), bundleID: "test.output.pinned")
        self.app = app
        self.pinnedApp = pinnedApp
        let processes = StubProcessMonitor()
        processes.activeApps = [app, pinnedApp]
        self.processes = processes
        let permission = AudioRecordingPermission()
        permission.status = .authorized
        let taps = OutputPriorityTapStore()
        self.taps = taps
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: devices,
            processMonitor: processes,
            deviceVolumeMonitor: volume,
            tapFactory: { app, uids, _ in
                let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
                taps.byPID[app.id] = tap
                return tap
            },
            isAlive: { !devices.unavailableDeviceIDs.contains($0) },
            startMonitorsAutomatically: false
        )
        engine.setDevice(for: app, deviceUID: nil)
        volume.deliverCurrentDefaultNotification()
    }

    func setPriorityEnabled(_ enabled: Bool) {
        engine.setOutputDevicePriorityEnabled(enabled)
    }

    func expectRoute(to device: AudioDevice, app requestedApp: AudioApp? = nil) async throws {
        let targetApp = requestedApp ?? app
        let tap = try #require(taps.byPID[targetApp.id])
        let deadline = ContinuousClock.now + .seconds(1)
        // The engine dispatches tap switches to MainActor tasks; allow those to run.
        while tap.currentDeviceUID != device.uid, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(tap.currentDeviceUID == device.uid)
        #expect(engine.getDeviceUID(for: targetApp) == device.uid)
    }

    func expectDevices(_ uids: [String]) async throws {
        let tap = try #require(taps.byPID[app.id])
        let deadline = ContinuousClock.now + .seconds(1)
        while tap.currentDeviceUIDs != uids, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(tap.currentDeviceUIDs == uids)
    }

    func expectCompletedSwitches(_ uids: [String]) async throws {
        let tap = try #require(taps.byPID[app.id])
        let deadline = ContinuousClock.now + .seconds(1)
        while (tap.switchCalls.count < uids.count || tap.currentDeviceUID != uids.last),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(tap.switchCalls.map(\.deviceUID) == uids)
        #expect(tap.currentDeviceUID == uids.last)
        #expect(engine.getDeviceUID(for: app) == uids.last)
    }
}

@MainActor
private final class OutputPriorityTapStore {
    var byPID: [pid_t: RecordingProcessTapController] = [:]
}

/// Unlike the shared mock, this models removals from both the device list and UID lookup.
@MainActor
private final class OutputPriorityDeviceMonitor: AudioDeviceProviding {
    var outputDevices: [AudioDevice] = []
    var inputDevices: [AudioDevice] = []
    var unavailableDeviceIDs: Set<AudioDeviceID> = []
    var onDeviceDisconnected: ((String, String) -> Void)?
    var onDeviceConnected: ((String, String) -> Void)?
    var onInputDeviceDisconnected: ((String, String) -> Void)?
    var onInputDeviceConnected: ((String, String) -> Void)?

    func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
    func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
    func connect(_ device: AudioDevice) {
        outputDevices.append(device)
        onDeviceConnected?(device.uid, device.name)
    }
    func disconnect(_ device: AudioDevice) {
        outputDevices.removeAll { $0.uid == device.uid }
        onDeviceDisconnected?(device.uid, device.name)
    }
    func start() {}
    func stop() {}
}

/// HAL writes update the cached default; tests deliver notifications separately,
/// avoiding a synchronous callback before the engine has registered its echo.
@MainActor
private final class OutputPriorityVolumeMonitor: DeviceVolumeProviding {
    let devices: OutputPriorityDeviceMonitor
    var defaultDeviceID: AudioDeviceID
    var defaultDeviceUID: String?
    var defaultInputDeviceUID: String?
    var volumes: [AudioDeviceID: Float] = [:]
    var muteStates: [AudioDeviceID: Bool] = [:]
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?
    private(set) var defaultWrites: [AudioDeviceID] = []

    init(devices: OutputPriorityDeviceMonitor, initialDefault: AudioDevice) {
        self.devices = devices
        defaultDeviceID = initialDefault.id
        defaultDeviceUID = initialDefault.uid
    }

    func emitDefaultChange(_ device: AudioDevice) {
        defaultDeviceID = device.id
        defaultDeviceUID = device.uid
        deliverCurrentDefaultNotification()
    }
    func deliverCurrentDefaultNotification() {
        if let uid = defaultDeviceUID { onDefaultDeviceChanged?(uid) }
    }
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let device = devices.outputDevices.first(where: { $0.id == deviceID }) else { return false }
        defaultWrites.append(deviceID)
        defaultDeviceID = device.id
        defaultDeviceUID = device.uid
        return true
    }
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool { true }
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) { volumes[deviceID] = volume }
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) { muteStates[deviceID] = muted }
    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { .hardware }
    func start() {}
    func stop() {}
}
