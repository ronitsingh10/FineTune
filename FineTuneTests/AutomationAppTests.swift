import AppKit
import Foundation
import Testing

@testable import FineTune

@MainActor
func makeAutomationEngine(apps: [AudioApp] = []) -> AudioEngine {
    let settings = SettingsManager(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        loginItem: AutomationTestLoginItem())
    let devices = MockAudioDeviceMonitor()
    let process = StubProcessMonitor()
    process.activeApps = apps
    return AudioEngine(
        permission: AudioRecordingPermission(), settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(), deviceProvider: devices, processMonitor: process,
        deviceVolumeMonitor: MockDeviceVolumeProviding(deviceMonitor: devices),
        startMonitorsAutomatically: false)
}
@MainActor
func automationApp(_ pid: Int32, id: String = "com.test.player") -> AudioApp {
    AudioApp(id: pid, processObjectIDs: [], name: "Player", icon: NSImage(), bundleID: id)
}

@Suite("App automation") @MainActor
struct AutomationAppTests {
    @Test func inactiveVolumeAndBoostAreSeparate() async {
        let engine = makeAutomationEngine()
        let service = AutomationService(engine: engine)
        let target: AutomationValue = .object(["appId": .string("com.test.player")])
        let result = await service.execute(
            .init(id: "1", method: "app.volume.set", params: ["target": target, "percent": .number(30)]))
        #expect(result.result?.object?["status"] == .string("stored"))
        #expect(engine.settingsManager.getVolume(for: "com.test.player") == 0.3)
        let boost = await service.execute(
            .init(id: "2", method: "app.boost.set", params: ["target": target, "boost": .number(4)]))
        #expect(boost.error == nil)
        #expect(engine.settingsManager.getBoost(for: "com.test.player") == .x4)
        #expect(engine.settingsManager.getVolume(for: "com.test.player") == 0.3)
    }
    @Test func sharedIdentityAddressesAllInstances() async {
        let apps = [automationApp(11001), automationApp(11002)]
        let engine = makeAutomationEngine(apps: apps)
        let service = AutomationService(engine: engine)
        let r = await service.execute(
            .init(
                id: "1", method: "app.mute.set",
                params: ["target": .object(["appId": .string("com.test.player")]), "muted": .bool(true)]))
        #expect(r.error == nil)
        #expect(engine.getMute(for: apps[0]))
        #expect(engine.getMute(for: apps[1]))
    }
    @Test func badRuntimeTargetDoesNotWriteInactiveSettings() async {
        let engine = makeAutomationEngine()
        let service = AutomationService(engine: engine)
        let r = await service.execute(
            .init(
                id: "1", method: "app.volume.set",
                params: [
                    "target": .object(["appId": .string("com.test.player"), "instanceId": .number(77)]),
                    "percent": .number(30),
                ]))
        #expect(r.error?.code == .notFound)
        #expect(engine.settingsManager.getVolume(for: "com.test.player") == nil)
    }
    @Test func percentStepsClampAndResetKeepsBoost() async {
        let engine = makeAutomationEngine()
        let service = AutomationService(engine: engine)
        let target: AutomationValue = .object(["appId": .string("com.test.player")])
        _ = await service.execute(
            .init(id: "1", method: "app.volume.set", params: ["target": target, "percent": .number(95)]))
        _ = await service.execute(
            .init(
                id: "2", method: "app.volume.step",
                params: ["target": target, "domain": .string("percent"), "delta": .number(10)]))
        #expect(engine.settingsManager.getVolume(for: "com.test.player") == 1)
        _ = await service.execute(.init(id: "3", method: "app.mute.toggle", params: ["target": target]))
        #expect(engine.settingsManager.getMute(for: "com.test.player") == true)
        _ = await service.execute(.init(id: "4", method: "app.audio.reset", params: ["target": target]))
        #expect(engine.settingsManager.getMute(for: "com.test.player") == false)
    }
    @Test func sharedIdentityReportsMixedMuteState() async {
        let apps = [automationApp(11003), automationApp(11004)]
        let e = makeAutomationEngine(apps: apps); let service = AutomationService(engine: e)
        e.setMute(for: apps[0], to: true); e.setMute(for: apps[1], to: false)
        let r = await service.execute(.init(id: "mixed", method: "app.get", params: ["target": .object(["appId": .string("com.test.player")])]))
        #expect(r.result?.object?["mixed"] == .bool(true))
    }

}
@Suite("Automation URL compatibility") @MainActor
struct AutomationURLCompatibilityTests {
    @Test func pairedParametersAndRangeStayCompatible() {
        let engine = makeAutomationEngine()
        let handler = URLHandler(audioEngine: engine)
        handler.handleURL(URL(string: "finetune://set-volumes?app=com.a&volume=40&app=com.b&volume=75")!)
        #expect(engine.settingsManager.getVolume(for: "com.a") == 0.4)
        #expect(engine.settingsManager.getVolume(for: "com.b") == 0.75)
        handler.handleURL(URL(string: "finetune://set-volumes?app=com.a&volume=400")!)
        #expect(engine.settingsManager.getVolume(for: "com.a") == 0.4)
        handler.handleURL(URL(string: "finetune://step-volume?app=com.a&direction=up")!)
        #expect(engine.settingsManager.getVolume(for: "com.a") == 0.4)
    }
}
