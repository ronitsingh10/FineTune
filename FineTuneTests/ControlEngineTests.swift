import XCTest
import AppKit
@testable import FineTune

@MainActor
private final class ControlTestTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1
    var isMuted = false
    var currentDeviceVolume: Float = 1
    var isDeviceMuted = false
    var audioLevel: Float = 0
    var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String?
    var pending: [String: CheckedContinuation<Void, Error>] = [:]

    init(app: AudioApp, deviceUIDs: [String]) { self.app = app; currentDeviceUIDs = deviceUIDs }
    func activate(initial: TapInitialState) throws {}
    func invalidate() {}
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}
    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        try await withCheckedThrowingContinuation { pending[newDeviceUID] = $0 }
        currentDeviceUIDs = [newDeviceUID]
    }
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }
}

@MainActor
private final class ControlTestVolume: DeviceVolumeProviding {
    var defaultDeviceID: UInt32 = 1
    var defaultDeviceUID: String? = "a"
    var defaultInputDeviceUID: String? = "mic"
    var volumes: [UInt32: Float] = [:]
    var muteStates: [UInt32: Bool] = [:]
    var onVolumeChanged: ((UInt32, Float) -> Void)?
    var onMuteChanged: ((UInt32, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?
    var succeeds = true
    var selectedInputs: [UInt32] = []
    var selectedOutputs: [UInt32] = []
    func setDefaultDevice(_ deviceID: UInt32) -> Bool { selectedOutputs.append(deviceID); return succeeds }
    func setDefaultInputDevice(_ deviceID: UInt32) -> Bool { selectedInputs.append(deviceID); return succeeds }
    func setVolume(for deviceID: UInt32, to volume: Float) {}
    func setMute(for deviceID: UInt32, to muted: Bool) {}
    func outputVolumeBackend(for deviceID: UInt32) -> VolumeControlTier { .hardware }
    func start() {}
    func stop() {}
}

@MainActor
private final class ControlEngineFixture {
    let settings: SettingsManager
    let permission = AudioRecordingPermission(status: .authorized)
    let devices = MockAudioDeviceMonitor()
    let processes = StubProcessMonitor()
    let volume = ControlTestVolume()
    var taps: [Int32: ControlTestTap] = [:]
    var failTapCreation = false
    lazy var engine = AudioEngine(
        permission: permission, settingsManager: settings, autoEQProfileManager: AutoEQProfileManager(loadAutomatically: false),
        deviceProvider: devices, processMonitor: processes, deviceVolumeMonitor: volume,
        tapFactory: { [unowned self] app, uids, _ in
            if failTapCreation { throw ControlFailure(code: "test", message: "Tap creation failed") }
            let tap = ControlTestTap(app: app, deviceUIDs: uids)
            taps[app.id] = tap
            return tap
        }, isAlive: { _ in true }, startMonitorsAutomatically: false
    )

    init(directory: URL) {
        settings = SettingsManager(directory: directory)
        for (index, uid) in ["a", "b", "c"].enumerated() {
            devices.addOutputDevice(AudioDevice(id: UInt32(index + 1), uid: uid, name: uid, icon: nil, supportsAutoEQ: false))
        }
        devices.inputDevices = [AudioDevice(id: 9, uid: "mic", name: "Mic", icon: nil, supportsAutoEQ: false)]
        processes.activeApps = [Self.app(pid: 101)]
    }

    static func app(pid: Int32) -> AudioApp {
        AudioApp(id: pid, processObjectIDs: [], name: "Player", icon: NSImage(), bundleID: "test.player")
    }
}

nonisolated final class ControlEngineTests: XCTestCase {
    @MainActor
    private func fixture() -> ControlEngineFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let f = ControlEngineFixture(directory: directory)
        addTeardownBlock {
            await MainActor.run { f.settings.flushSync() }
            try? FileManager.default.removeItem(at: directory)
        }
        return f
    }

    @MainActor
    func testAmbiguousMissingAndStaleAppResolution() throws {
        let f = fixture()
        f.processes.activeApps.append(ControlEngineFixture.app(pid: 102))
        assertFailure("ambiguousApp") { try f.engine.performControlCommand(.mute("test.player", nil, true)) }
        assertFailure("appNotFound") { try f.engine.performControlCommand(.mute("other", nil, true)) }
        assertFailure("staleApp") { try f.engine.performControlCommand(.mute("other", 101, true)) }
        assertFailure("staleApp") { try f.engine.performControlCommand(.mute("test.player", 103, true)) }
        try f.engine.performControlCommand(.mute("test.player", 102, true))
        XCTAssertTrue(f.engine.getMute(for: f.processes.activeApps[1]))
        XCTAssertFalse(f.engine.getMute(for: f.processes.activeApps[0]))
        guard case .array(let rows) = f.engine.controlState().object?["apps"] else { return XCTFail("Missing apps") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].object?["pids"], .array([.number(101)]))
        XCTAssertEqual(rows[1].object?["pids"], .array([.number(102)]))
    }

    @MainActor
    func testPermissionMultiModeAndWrongDirection() throws {
        let f = fixture()
        let app = f.processes.activeApps[0]
        f.permission.status = .denied
        assertFailure("permissionDenied") { try f.engine.performControlCommand(.volume("test.player", 101, 0.5)) }
        assertFailure("permissionDenied") { try f.engine.performControlCommand(.mute("test.player", 101, true)) }
        try f.engine.performControlCommand(.preferredInput("mic"))
        f.permission.status = .authorized
        f.engine.volumeState.setDeviceSelectionMode(for: app.id, to: .multi, identifier: app.persistenceIdentifier)
        assertFailure("unsupportedRouting") { try f.engine.performControlCommand(.routing("test.player", 101, "a")) }
        try f.engine.performControlCommand(.mute("test.player", 101, true))
        XCTAssertTrue(f.engine.getMute(for: app))
        assertFailure("deviceNotFound") { try f.engine.performControlCommand(.preferredInput("a")) }
        assertFailure("deviceNotFound") { try f.engine.performControlCommand(.defaultOutput("mic")) }
        assertFailure("deviceNotFound") { try f.engine.performControlCommand(.defaultOutput("gone")) }
    }

    @MainActor
    func testPreferredInputPreservesPolicyAndPropagatesFailure() throws {
        let f = fixture()
        f.settings.appSettings.lockInputDevice = false
        try f.engine.performControlCommand(.preferredInput("mic"))
        XCTAssertEqual(f.volume.selectedInputs, [9])
        XCTAssertEqual(f.settings.preferredInputDeviceUID, "mic")
        XCTAssertEqual(f.settings.lockedInputDeviceUID, "mic")
        XCTAssertFalse(f.settings.appSettings.lockInputDevice)
        f.volume.succeeds = false
        assertFailure("commandFailed") { try f.engine.performControlCommand(.preferredInput("mic")) }
        assertFailure("commandFailed") { try f.engine.performControlCommand(.defaultOutput("b")) }
        XCTAssertEqual(f.engine.controlState().object?["defaultInput"], .string("mic"))
        XCTAssertEqual(f.engine.controlState().object?["defaultOutput"], .string("a"))
    }

    @MainActor
    func testStateSchemaExplicitNullsAndDeviceOrdering() throws {
        let f = fixture()
        let state = try XCTUnwrap(f.engine.controlState().object)
        XCTAssertEqual(Set(state.keys), ["apps", "devices", "defaultOutput", "defaultInput", "inputPolicy", "permission"])
        guard case .array(let apps) = state["apps"], case .array(let devices) = state["devices"] else { return XCTFail("Missing arrays") }
        let app = try XCTUnwrap(apps.first?.object)
        XCTAssertEqual(Set(app.keys), ["appId", "pids", "name", "active", "volume", "boost", "muted", "routing"])
        XCTAssertEqual(app["active"], .bool(true))
        XCTAssertEqual(app["routing"]?.object?["appliedDeviceUIDs"], .null)
        XCTAssertEqual(app["routing"]?.object?["error"], .null)
        XCTAssertEqual(app["routing"]?.object?["status"], .string("unavailable"))
        XCTAssertEqual(devices.compactMap { $0.object?["uid"]?.string }, ["mic", "a", "b", "c"])
        XCTAssertEqual(devices.first?.object?["direction"], .string("input"))
        XCTAssertEqual(devices.first?.object?["volume"], .null)
        XCTAssertEqual(devices.first?.object?["muted"], .null)
        XCTAssertEqual(state["inputPolicy"]?.object?["preferredDeviceUID"], .null)
        XCTAssertEqual(state["inputPolicy"]?.object?["lockedDeviceUID"], .null)
        f.processes.activeApps = []
        XCTAssertEqual(f.engine.controlState().object?["apps"], .array([]))
    }

    @MainActor
    func testTapCreationFailureIsAsynchronousRoutingStateNotCommandFailure() throws {
        let f = fixture()
        f.failTapCreation = true
        XCTAssertNoThrow(try f.engine.performControlCommand(.routing("test.player", 101, "a")))
        XCTAssertEqual(f.engine.controlRouting[101]?.status, "failed")
        XCTAssertEqual(f.engine.controlRouting[101]?.error?.code, "routingFailed")
        XCTAssertNil(f.engine.controlAppliedDeviceUIDs(for: 101))
    }

    @MainActor
    func testAsyncRoutingSuccessFailureAndSupersededCompletion() async throws {
        let f = fixture()
        let app = f.processes.activeApps[0]
        f.engine.setDevice(for: app, deviceUID: "a")
        let tap = try XCTUnwrap(f.taps[101])
        XCTAssertEqual(f.engine.controlRouting[101]?.status, "applied")
        f.engine.setDevice(for: app, deviceUID: "b")
        await waitForPending("b", tap: tap)
        XCTAssertEqual(f.engine.controlRouting[101]?.status, "pending")
        f.engine.setDevice(for: app, deviceUID: "c")
        await waitForPending("c", tap: tap)
        tap.pending.removeValue(forKey: "c")?.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.engine.controlRouting[101]?.status, "applied")
        tap.pending.removeValue(forKey: "b")?.resume(throwing: ControlFailure(code: "test", message: "Superseded"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.engine.controlRouting[101]?.status, "applied")
        XCTAssertNil(f.engine.controlRouting[101]?.error)
        XCTAssertEqual(f.engine.controlAppliedDeviceUIDs(for: 101), ["c"])
        f.engine.setDevice(for: app, deviceUID: "b")
        await waitForPending("b", tap: tap)
        tap.pending.removeValue(forKey: "b")?.resume(throwing: ControlFailure(code: "test", message: "Failed"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.engine.controlRouting[101]?.status, "failed")
        XCTAssertEqual(f.engine.controlRouting[101]?.error?.code, "routingFailed")
    }

    @MainActor
    private func waitForPending(_ uid: String, tap: ControlTestTap) async {
        for _ in 0..<100 where tap.pending[uid] == nil { await Task.yield() }
        XCTAssertNotNil(tap.pending[uid])
    }

    @MainActor
    private func assertFailure(_ code: String, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, code, file: file, line: line)
        }
    }
}
