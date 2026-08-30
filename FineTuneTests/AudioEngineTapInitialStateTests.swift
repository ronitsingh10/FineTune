// FineTuneTests/AudioEngineTapInitialStateTests.swift
//
// Verifies AudioEngine derives TapInitialState from persisted settings and
// hands it to activate(initial:) before any post-activation mutation.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Recording Mock

/// Records every method invocation against `ProcessTapControlling` in order.
/// Tests assert on `events` to verify the engine's apply-initial-state contract.
@MainActor
final class RecordingProcessTapController: ProcessTapControlling {
    enum Event: Equatable {
        case activate(TapInitialStateSnapshot)
        case updateEQSettings(EQSettings)
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case updateAUEffectChain([AUEffectChainEntry])
        case updateDeviceAUEffectChain([AUEffectChainEntry])
        case setAUChainBypassed(Bool)
        case setDeviceAUChainBypassed(Bool)
        case invalidate
    }

    /// Plain snapshot of `TapInitialState` so test asserts don't depend on
    /// the source-type's identity (defensive against future mutations).
    struct TapInitialStateSnapshot: Equatable {
        var eqSettings: EQSettings
        var autoEQProfileID: String?
        var autoEQPreampEnabled: Bool
        var loudnessVolume: Float
        var loudnessCompensationEnabled: Bool
        var loudnessEqualizerSettings: LoudnessEqualizerSettings
        var appAUEffectChain: [AUEffectChainEntry]
        var deviceAUEffectChain: [AUEffectChainEntry]
        var appAUBypassed: Bool
        var deviceAUBypassed: Bool

        @MainActor
        init(_ s: TapInitialState) {
            self.eqSettings = s.eqSettings
            self.autoEQProfileID = s.autoEQProfile?.id
            self.autoEQPreampEnabled = s.autoEQPreampEnabled
            self.loudnessVolume = s.loudnessVolume
            self.loudnessCompensationEnabled = s.loudnessCompensationEnabled
            self.loudnessEqualizerSettings = s.loudnessEqualizerSettings
            self.appAUEffectChain = s.appAUEffectChain
            self.deviceAUEffectChain = s.deviceAUEffectChain
            self.appAUBypassed = s.appAUBypassed
            self.deviceAUBypassed = s.deviceAUBypassed
        }
    }

    let app: AudioApp
    private(set) var events: [Event] = []

    // Mutable surface — recorded as plain property writes (not events).
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil
    var failedAppAUEntryIDs: Set<UUID> = []
    var failedDeviceAUEntryIDs: Set<UUID> = []

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        events.append(.activate(TapInitialStateSnapshot(initial)))
    }

    func invalidate() {
        events.append(.invalidate)
    }

    func updateEQSettings(_ settings: EQSettings) {
        events.append(.updateEQSettings(settings))
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        events.append(.updateAutoEQProfile(profileID: profile?.id))
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        events.append(.setAutoEQPreampEnabled(enabled))
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        events.append(.updateLoudnessCompensation(volume: volume, enabled: enabled))
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        events.append(.updateLoudnessEqualization(settings))
    }

    func updateAUEffectChain(_ entries: [AUEffectChainEntry]) { events.append(.updateAUEffectChain(entries)) }
    func updateDeviceAUEffectChain(_ entries: [AUEffectChainEntry]) { events.append(.updateDeviceAUEffectChain(entries)) }
    func setAUChainBypassed(_ bypassed: Bool) { events.append(.setAUChainBypassed(bypassed)) }
    func setDeviceAUChainBypassed(_ bypassed: Bool) { events.append(.setDeviceAUChainBypassed(bypassed)) }
    func failedAUEffectEntryIDs() -> Set<UUID> { failedAppAUEntryIDs }
    func failedDeviceAUEffectEntryIDs() -> Set<UUID> { failedDeviceAUEntryIDs }

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {}
}

// MARK: - Process monitor stub

@MainActor
final class StubProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let app: AudioApp
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
}

@MainActor
private func makeFixture(
    supportsAutoEQ: Bool = true,
    deviceVolume: Float = 0.75,
    editorInvalidator: (@MainActor (Set<UUID>, Bool) -> Void)? = nil
) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: supportsAutoEQ
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = deviceVolume

    let app = AudioApp(
        id: 12345,
        processObjectIDs: [],
        name: "TestApp",
        icon: NSImage(),
        bundleID: "com.test.tapinitial"
    )

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    // Capture every tap the factory hands out so tests can read the captured
    // event log. Mutable box lets the closure write into the test scope.
    let box = TapBox()

    // ensureTapExists guards on permission.status == .authorized. The TCC SPI
    // preflight returns -1 (unknown) under xctest, so we force it to authorized
    // via the internal(set) status property exposed by @testable import.
    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            box.last = tap
            return tap
        },
        editorInvalidator: editorInvalidator,
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        deviceVolume: mockVolume,
        app: app,
        device: device,
        lastTap: { box.last }
    )
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
}

@MainActor
private func waitForTapEvent(
    _ tap: RecordingProcessTapController,
    matching predicate: @escaping (RecordingProcessTapController.Event) -> Bool
) async -> Bool {
    for _ in 0..<32 {
        if tap.events.contains(where: predicate) { return true }
        await Task.yield()
    }
    return false
}

// MARK: - Suite

@Suite("AudioEngine.tapInitialState — first-sound fix (PR-1)")
@MainActor
struct AudioEngineTapInitialStateTests {

    @Test("App chain mutation invalidates exactly its outgoing editor IDs")
    func appChainInvalidationScope() {
        var recorded: [Set<UUID>] = []
        let fix = makeFixture(editorInvalidator: { ids, _ in recorded.append(ids) })
        let first = AUEffectChainEntry(plugin: testAUPlugin(name: "First"))
        let second = AUEffectChainEntry(plugin: testAUPlugin(name: "Second", subtype: 2))
        let unrelated = AUEffectChainEntry(plugin: testAUPlugin(name: "Other", subtype: 3))
        fix.settings.setAUEffectChain([first, second], for: fix.app.persistenceIdentifier)
        fix.engine.reorderAUEffects(for: fix.app, entries: [second, first])
        #expect(recorded == [Set([first.id, second.id])])
        #expect(!recorded[0].contains(unrelated.id))
    }

    @Test("Device chain mutation invalidates exactly its outgoing editor IDs")
    func deviceChainInvalidationScope() {
        var recorded: [Set<UUID>] = []
        let fix = makeFixture(editorInvalidator: { ids, _ in recorded.append(ids) })
        let first = AUEffectChainEntry(plugin: testAUPlugin(name: "First"))
        let second = AUEffectChainEntry(plugin: testAUPlugin(name: "Second", subtype: 4))
        let unrelated = AUEffectChainEntry(plugin: testAUPlugin(name: "Other", subtype: 5))
        fix.settings.setDeviceAUEffectChain([first, second], for: fix.device.uid)
        fix.engine.reorderDeviceAUEffects(deviceUID: fix.device.uid, entries: [second, first])
        #expect(recorded == [Set([first.id, second.id])])
        #expect(!recorded[0].contains(unrelated.id))
    }

    @Test("Successful destination adoption invalidates destination editors only")
    func destinationAdoptionInvalidationScope() {
        var recorded: [Set<UUID>] = []
        let fix = makeFixture(editorInvalidator: { ids, _ in recorded.append(ids) })
        let destination = AUEffectChainEntry(plugin: testAUPlugin(name: "Destination", subtype: 7))
        fix.settings.setDeviceAUEffectChain([destination], for: fix.device.uid)
        fix.engine.invalidateDestinationEditorAfterSuccessfulRoute(deviceUID: fix.device.uid)
        #expect(recorded == [Set([destination.id])])
    }

    @Test("Failed route leaves source editors and state untouched")
    func failedRouteDoesNotInvalidateEditors() {
        var recorded: [Set<UUID>] = []
        let fix = makeFixture(editorInvalidator: { ids, _ in recorded.append(ids) })
        let source = AUEffectChainEntry(plugin: testAUPlugin(name: "Source", subtype: 8))
        fix.settings.setDeviceAUEffectChain([source], for: fix.device.uid)
        fix.engine.handleRouteEditorInvalidation(success: false, destinationUID: fix.device.uid)
        #expect(recorded.isEmpty)
        #expect(fix.settings.getDeviceAUEffectChain(for: fix.device.uid) == [source])
    }

    // MARK: Single-knob derivation

    @Test("EQ settings persisted for this app land in TapInitialState.eqSettings")
    func eqSettingsAreCarried() throws {
        let fix = makeFixture()
        let custom = EQSettings(bandGains: [3, 0, -2, 0, 0, 0, 0, 0, 0, 4], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.eqSettings == custom)
    }

    @Test("autoEQPreampEnabled mirrors settingsManager.autoEQPreampEnabled",
          arguments: [true, false])
    func autoEQPreampEnabledMirrored(value: Bool) throws {
        let fix = makeFixture()
        fix.settings.autoEQPreampEnabled = value

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQPreampEnabled == value)
    }

    @Test("loudnessCompensationEnabled mirrors appSettings.loudnessCompensationEnabled",
          arguments: [true, false])
    func loudnessCompensationFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessCompensationEnabled == value)
    }

    @Test("loudnessEqualizerSettings.enabled mirrors appSettings.loudnessEqualizationEnabled",
          arguments: [true, false])
    func loudnessEqualizerFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessEqualizationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessEqualizerSettings.enabled == value)
    }

    @Test("loudnessVolume = currentDeviceVolume × per-app volume")
    func loudnessVolumeIsProduct() throws {
        let fix = makeFixture(deviceVolume: 0.5)
        fix.engine.volumeState.setVolume(for: fix.app.id, to: 0.4, identifier: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        // applyTapOutputState() runs before tapInitialState() is built, so
        // currentDeviceVolume is 0.5 (from MockDeviceVolumeProviding.volumes).
        // loudnessVolume should be deviceVolume (0.5) × appVolume (0.4) = 0.2.
        #expect(abs(snap.loudnessVolume - 0.2) < 1e-6)
    }

    // MARK: AutoEQ profile resolution

    @Test("autoEQProfile is nil when the device does not support AutoEQ")
    func autoEQNilForUnsupportedDevice() throws {
        let fix = makeFixture(supportsAutoEQ: false)
        // Even if a selection exists, an unsupported device must skip AutoEQ.
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when no selection is persisted for the device")
    func autoEQNilWithNoSelection() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        // Don't set any selection.

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when the selection is disabled")
    func autoEQNilWhenSelectionDisabled() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: false)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when selection is enabled but profile is not in the cache")
    func autoEQNilWhenProfileNotCached() throws {
        // Default AutoEQProfileManager has no profiles cached for "missing-id".
        // The pre-activate synchronous lookup must return nil so that
        // ensureTapExists falls through to the async resolve branch.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    // MARK: Ordering / post-activation behaviour

    @Test("activate(initial:) is the first event the controller observes")
    func activateIsFirstEvent() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let firstEvent = try #require(tap.events.first)
        if case .activate = firstEvent {
            // ok
        } else {
            Issue.record("First event was \(firstEvent), expected .activate")
        }
    }

    @Test("No EQ/AutoEQ/Loudness mutation runs BEFORE activate(initial:) — the apply-initial-state contract")
    func noMutationBeforeActivate() throws {
        // The core PR-1 invariant: every processor-state knob the audio thread
        // can observe must be set via TapInitialState, not via post-construction
        // calls that race with AudioDeviceStart. We assert this by checking
        // that no .updateEQSettings / .updateAutoEQProfile / .setAutoEQPreampEnabled
        // / .updateLoudnessCompensation / .updateLoudnessEqualization is recorded
        // BEFORE the .activate event in the tap's event log.
        //
        // Exercises a realistic config (AutoEQ-capable device with an enabled
        // selection whose profile is uncached) so applyAutoEQToTap runs
        // post-activate — proving the engine's fallback path doesn't accidentally
        // fire before activate.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )
        let custom = EQSettings(bandGains: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = true
        s.loudnessEqualizationEnabled = true
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let activateIndex = try #require(tap.events.firstIndex { event in
            if case .activate = event { return true }
            return false
        })

        for event in tap.events.prefix(activateIndex) {
            switch event {
            case .updateEQSettings, .updateAutoEQProfile, .setAutoEQPreampEnabled,
                 .updateLoudnessCompensation, .updateLoudnessEqualization,
                 .updateAUEffectChain, .updateDeviceAUEffectChain,
                 .setAUChainBypassed, .setDeviceAUChainBypassed:
                Issue.record("Pre-activate mutation breaks the apply-initial-state contract: \(event)")
            case .activate, .invalidate:
                break
            }
        }
    }

    @Test("Cache-miss AutoEQ: applyAutoEQToTap fires its sync nil-set after activate")
    func cacheMissTriggersPostActivateNilSet() throws {
        // Device supports AutoEQ + selection is enabled but profile is missing
        // from cache → ensureTapExists calls applyAutoEQToTap, which sets the
        // profile to nil synchronously before kicking off async resolution.
        // Verifies the engine's fallback path is reached when (and only when)
        // the synchronous pre-activate lookup misses.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        // The first event must still be .activate (apply-initial-state ordering)
        if case .activate = tap.events.first {
            // ok
        } else {
            Issue.record("activate(initial:) was not first event")
        }
        // A post-activate updateAutoEQProfile(nil) must be present from
        // applyAutoEQToTap's sync nil-set on cache miss.
        let postActivateAutoEQ = tap.events.dropFirst().compactMap { event -> String?? in
            if case let .updateAutoEQProfile(id) = event { return Optional(id) }
            return nil
        }
        #expect(postActivateAutoEQ.contains(where: { $0 == nil }))
    }

    @Test("Persisted app and device AU state is captured before the first tap callback")
    func auStateIsCarriedBeforeActivation() throws {
        let fix = makeFixture()
        let appEntry = AUEffectChainEntry(plugin: testAUPlugin(name: "App FX"))
        let deviceEntry = AUEffectChainEntry(plugin: testAUPlugin(name: "Device FX", subtype: 0x64657631))
        fix.settings.setAUEffectChain([appEntry], for: fix.app.persistenceIdentifier)
        fix.settings.setDeviceAUEffectChain([deviceEntry], for: fix.device.uid)
        fix.settings.setAppAUBypassed(true, for: fix.app.persistenceIdentifier)
        fix.settings.setDeviceAUBypassed(true, for: fix.device.uid)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let snap = try #require(capturedInitial(fix))
        #expect(snap.appAUEffectChain == [appEntry])
        #expect(snap.deviceAUEffectChain == [deviceEntry])
        #expect(snap.appAUBypassed)
        #expect(snap.deviceAUBypassed)
        #expect(tap.events.first == .activate(snap))
    }

    @Test("Reordering an active app AU chain persists and rebuilds the live chain")
    func appAUReorderPersistsAndUpdatesTap() throws {
        let fix = makeFixture()
        let first = AUEffectChainEntry(plugin: testAUPlugin(name: "First"))
        let second = AUEffectChainEntry(plugin: testAUPlugin(name: "Second", subtype: 0x61707032))
        fix.settings.setAUEffectChain([first, second], for: fix.app.persistenceIdentifier)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let reordered = [second, first]

        fix.engine.reorderAUEffects(for: fix.app, entries: reordered)

        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier) == reordered)
        let tap = try #require(fix.lastTap())
        #expect(tap.events.contains(.updateAUEffectChain(reordered)))
    }

    @Test("Reordering an active device AU chain persists and rebuilds affected taps")
    func deviceAUReorderPersistsAndUpdatesTap() throws {
        let fix = makeFixture()
        let first = AUEffectChainEntry(plugin: testAUPlugin(name: "First"))
        let second = AUEffectChainEntry(plugin: testAUPlugin(name: "Second", subtype: 0x64657632))
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let reordered = [second, first]

        fix.engine.reorderDeviceAUEffects(deviceUID: fix.device.uid, entries: reordered)

        #expect(fix.settings.getDeviceAUEffectChain(for: fix.device.uid) == reordered)
        let tap = try #require(fix.lastTap())
        #expect(tap.events.contains(.updateDeviceAUEffectChain(reordered)))
    }

    @Test("Lazy AU state hydration preserves persisted bypass while mutating chains")
    func lazyAUStatePreservesPersistedBypass() {
        let fix = makeFixture()
        let entry = AUEffectChainEntry(plugin: testAUPlugin(name: "Persisted FX"))
        fix.settings.setAUEffectChain([entry], for: fix.app.persistenceIdentifier)
        fix.settings.setAppAUBypassed(true, for: fix.app.persistenceIdentifier)
        fix.settings.setDeviceAUEffectChain([entry], for: fix.device.uid)
        fix.settings.setDeviceAUBypassed(true, for: fix.device.uid)

        fix.engine.reorderAUEffects(for: fix.app, entries: [entry])
        fix.engine.reorderDeviceAUEffects(deviceUID: fix.device.uid, entries: [entry])

        #expect(fix.engine.appAU[fix.app.persistenceIdentifier]?.isBypassed == true)
        #expect(fix.engine.deviceAU[fix.device.uid]?.isBypassed == true)
        #expect(fix.settings.getAppAUBypassed(for: fix.app.persistenceIdentifier))
        #expect(fix.settings.getDeviceAUBypassed(for: fix.device.uid))
    }

    @Test("AU host failures are reflected into app and device live chain state")
    func failedAUEntriesArePublishedToLiveState() throws {
        let fix = makeFixture()
        let entry = AUEffectChainEntry(plugin: testAUPlugin(name: "Unavailable FX"))
        fix.settings.setAUEffectChain([entry], for: fix.app.persistenceIdentifier)
        fix.settings.setDeviceAUEffectChain([entry], for: fix.device.uid)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.failedAppAUEntryIDs = [entry.id]
        tap.failedDeviceAUEntryIDs = [entry.id]

        fix.engine.reorderAUEffects(for: fix.app, entries: [entry])
        fix.engine.reorderDeviceAUEffects(deviceUID: fix.device.uid, entries: [entry])

        #expect(fix.engine.appAU[fix.app.persistenceIdentifier]?.failedEntryIDs == [entry.id])
        #expect(fix.engine.deviceAU[fix.device.uid]?.failedEntryIDs == [entry.id])
    }

    @Test("A single-device switch applies the destination AU chain and bypass")
    func deviceSwitchAppliesDestinationAUState() async throws {
        let fix = makeFixture()
        let destination = AudioDevice(id: 100, uid: "uid-destination", name: "Destination", icon: nil, supportsAutoEQ: false)
        fix.deviceMonitor.addOutputDevice(destination)
        fix.deviceVolume.volumes[destination.id] = 0.8
        let destinationEntry = AUEffectChainEntry(plugin: testAUPlugin(name: "Destination FX"))
        fix.settings.setDeviceAUEffectChain([destinationEntry], for: destination.uid)
        fix.settings.setDeviceAUBypassed(true, for: destination.uid)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setDevice(for: fix.app, deviceUID: destination.uid)

        #expect(await waitForTapEvent(tap) { $0 == .updateDeviceAUEffectChain([destinationEntry]) })
        #expect(tap.events.contains(.setDeviceAUChainBypassed(true)))
    }

    @Test("A multi-device update applies the primary destination AU chain and bypass")
    func multiDeviceUpdateAppliesDestinationAUState() async throws {
        let fix = makeFixture()
        let destination = AudioDevice(id: 101, uid: "uid-multi", name: "Multi Destination", icon: nil, supportsAutoEQ: false)
        fix.deviceMonitor.addOutputDevice(destination)
        fix.deviceVolume.volumes[destination.id] = 0.8
        let destinationEntry = AUEffectChainEntry(plugin: testAUPlugin(name: "Multi FX"))
        fix.settings.setDeviceAUEffectChain([destinationEntry], for: destination.uid)
        fix.settings.setDeviceAUBypassed(true, for: destination.uid)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setDeviceSelectionMode(for: fix.app, to: .multi)
        fix.engine.setSelectedDeviceUIDs(for: fix.app, to: [destination.uid])

        #expect(await waitForTapEvent(tap) { $0 == .updateDeviceAUEffectChain([destinationEntry]) })
        #expect(tap.events.contains(.setDeviceAUChainBypassed(true)))
    }
}

// MARK: - Helpers

@MainActor
private func capturedInitial(_ fix: Fixture) -> RecordingProcessTapController.TapInitialStateSnapshot? {
    guard let tap = fix.lastTap() else { return nil }
    for event in tap.events {
        if case let .activate(snapshot) = event { return snapshot }
    }
    return nil
}

private func testAUPlugin(name: String, subtype: UInt32 = 0x61707031) -> AUPluginDescriptor {
    AUPluginDescriptor(
        componentType: kAudioUnitType_Effect,
        componentSubType: subtype,
        componentManufacturer: 0x74657374,
        name: name,
        manufacturer: "Test",
        version: 1
    )
}

// MARK: - Mock contract

@Suite("RecordingProcessTapController — protocol contract")
@MainActor
struct RecordingProcessTapControllerContractTests {
    @Test("Mock records activate, then mutation events, in invocation order")
    func recordsCallOrder() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        try tap.activate(initial: TapInitialState())
        tap.updateEQSettings(EQSettings.flat)
        tap.updateAutoEQProfile(nil)

        #expect(tap.events.count == 3)
        if case .activate = tap.events[0] {} else { Issue.record("expected .activate at 0") }
        if case .updateEQSettings = tap.events[1] {} else { Issue.record("expected .updateEQSettings at 1") }
        if case .updateAutoEQProfile = tap.events[2] {} else { Issue.record("expected .updateAutoEQProfile at 2") }
    }

    @Test("Default property values match real controller defaults")
    func defaultsMatchProductionController() {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // ProcessTapController's nonisolated(unsafe) defaults from source.
        #expect(tap.volume == 1.0)
        #expect(tap.isMuted == false)
        #expect(tap.currentDeviceVolume == 1.0)
        #expect(tap.isDeviceMuted == false)
        #expect(tap.audioLevel == 0.0)
        #expect(tap.tapSourceDeviceUID == nil)
        #expect(tap.currentDeviceUID == "uid")
    }

    @Test("Backward-compatible activate() convenience routes through activate(initial:)")
    func convenienceActivateRoutesThroughInitial() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // Convenience extension on the protocol: should funnel through activate(initial:)
        // with a default TapInitialState — proves no caller can sneak around the
        // initial-state contract by calling the old no-arg overload.
        try tap.activate()
        if case let .activate(snap) = tap.events.first {
            #expect(snap.autoEQProfileID == nil)
            #expect(snap.loudnessCompensationEnabled == false)
            #expect(snap.loudnessEqualizerSettings.enabled == false)
            #expect(snap.autoEQPreampEnabled == false)
            #expect(snap.eqSettings == EQSettings.flat)
            #expect(snap.loudnessVolume == 1.0)
        } else {
            Issue.record("activate() did not record an .activate event")
        }
    }
}
