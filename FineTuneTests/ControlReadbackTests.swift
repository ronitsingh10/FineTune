import XCTest
@testable import FineTune

@MainActor
private final class ReadbackProbe {
    var backends = 0
    var readability = 0
    var hardwareAvailable = true
}

nonisolated final class ControlReadbackTests: XCTestCase {
    @MainActor
    func testSnapshotsReadCachedBackendWithoutHALProbes() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: root)
        defer { settings.flushSync(); try? FileManager.default.removeItem(at: root) }
        let probe = ReadbackProbe()
        let monitor = DeviceVolumeMonitor(
            deviceMonitor: AudioDeviceMonitor(), settingsManager: settings,
            hardwareVolumeAvailable: { _ in probe.backends += 1; return probe.hardwareAvailable },
            hardwareReadability: { _, _ in probe.readability += 1; return (true, true) }
        )
        let devices = MockAudioDeviceMonitor()
        devices.addOutputDevice(AudioDevice(id: 42, uid: "output", name: "Output", icon: nil, supportsAutoEQ: false))
        let engine = AudioEngine(
            permission: AudioRecordingPermission(status: .authorized), settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(loadAutomatically: false),
            deviceProvider: devices, processMonitor: StubProcessMonitor(), deviceVolumeMonitor: monitor,
            startMonitorsAutomatically: false
        )
        monitor.refreshControlReadability(for: 42, input: false)
        XCTAssertEqual(probe.backends, 1)
        XCTAssertEqual(probe.readability, 1)
        for _ in 0..<100 { _ = engine.controlState() }
        XCTAssertEqual(probe.backends, 1)
        XCTAssertEqual(probe.readability, 1)
        probe.hardwareAvailable = false
        monitor.refreshControlReadability(for: 42, input: false)
        XCTAssertEqual(monitor.controlReadback(for: 42, input: false).source, "software")
        for _ in 0..<100 { _ = engine.controlState() }
        XCTAssertEqual(probe.backends, 2)
        XCTAssertEqual(probe.readability, 1)
    }
}
