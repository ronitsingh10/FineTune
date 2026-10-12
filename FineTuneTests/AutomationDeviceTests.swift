import Foundation
import Testing

@testable import FineTune

@Suite("Device and routing automation") @MainActor
struct AutomationDeviceTests {
    @Test func failedInputSelectionDoesNotEnableLock() async {
        let e = makeAutomationEngine()
        let devices = e.deviceMonitor as! MockAudioDeviceMonitor
        devices.inputDevices = [
            .init(id: 123457, uid: "fixture-input", name: "Input", icon: nil, supportsAutoEQ: false)
        ]
        let lockBefore = e.settingsManager.appSettings.lockInputDevice
        let uidBefore = e.settingsManager.lockedInputDeviceUID
        (e.deviceVolumeMonitor as! MockDeviceVolumeProviding).inputSelectionSucceeds = false
        let r = await AutomationService(engine: e).execute(
            .init(
                id: "input", method: "input.lock.set",
                params: ["deviceUID": .string("fixture-input"), "enabled": .bool(true)]))
        #expect(r.error?.code == .unavailable)
        #expect(e.settingsManager.appSettings.lockInputDevice == lockBefore)
        #expect(e.settingsManager.lockedInputDeviceUID == uidBefore)
    }
    @Test func missingDeviceDoesNotMutate() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let r = await s.execute(
            .init(
                id: "1", method: "device.volume.set",
                params: ["target": .object(["deviceUID": .string("absent")]), "percent": .number(25)]))
        #expect(r.error?.code == .unavailable)
        #expect(e.deviceVolumeMonitor.volumes.isEmpty)
    }
    @Test func routesInactiveOnlyWithOfflinePermission() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let params: [String: AutomationValue] = [
            "target": .object(["appId": .string("com.test.player")]), "mode": .string("single"),
            "deviceUIDs": .array([.string("offline")]),
        ]
        let denied = await s.execute(.init(id: "1", method: "app.routing.set", params: params))
        #expect(denied.error?.code == .unavailable)
        #expect(e.settingsManager.getDeviceRouting(for: "com.test.player") == nil)
        var allowed = params
        allowed["allowOffline"] = .bool(true)
        let r = await s.execute(.init(id: "2", method: "app.routing.set", params: allowed))
        #expect(r.result?.object?["status"] == .string("stored"))
        #expect(e.settingsManager.getDeviceRouting(for: "com.test.player") == "offline")
    }
    @Test func rejectsRoutingBeforeChangingMode() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let r = await s.execute(
            .init(
                id: "1", method: "app.routing.set",
                params: [
                    "target": .object(["appId": .string("com.test.player")]), "mode": .string("multi"),
                    "deviceUIDs": .array([]),
                ]))
        #expect(r.error?.code == .invalidParameter)
        #expect(e.getDeviceSelectionModeForInactive(identifier: "com.test.player") == .single)
    }
    @Test func deviceManagementKeepsDirectionSeparate() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        _ = await s.execute(
            .init(
                id: "1", method: "device.hidden.set",
                params: [
                    "target": .object(["deviceUID": .string("offline"), "direction": .string("input")]),
                    "hidden": .bool(true),
                ]))
        #expect(e.settingsManager.hiddenInputDeviceUIDs.contains("offline"))
        #expect(!e.settingsManager.hiddenOutputDeviceUIDs.contains("offline"))
    }
    @Test func missingDDCServiceCannotReportApplied() async {
        let e = makeAutomationEngine()
        let devices = e.deviceMonitor as! MockAudioDeviceMonitor
        let volume = e.deviceVolumeMonitor as! MockDeviceVolumeProviding
        devices.addOutputDevice(
            .init(id: 123456, uid: "fixture-ddc", name: "Fixture Monitor", icon: nil, supportsAutoEQ: false))
        volume.defaultTier = .ddc
        var rejected = false
        do {
            _ = try await DeviceAutomationAdapter(engine: e).execute(
                method: "device.volume.set",
                params: ["target": .object(["deviceUID": .string("fixture-ddc")]), "percent": .number(30)])
        } catch let error as AutomationError { rejected = error.code == .unavailable } catch {}
        #expect(rejected)
    }

    @Test func inputSelectionPreservesPreferredDevice() async {
        let e = makeAutomationEngine()
        let devices = e.deviceMonitor as! MockAudioDeviceMonitor
        devices.inputDevices = [
            .init(id: 123457, uid: "fixture-input", name: "Fixture Input", icon: nil, supportsAutoEQ: false)
        ]
        let r = await AutomationService(engine: e).execute(
            .init(
                id: "input", method: "device.default.set",
                params: [
                    "target": .object(["deviceUID": .string("fixture-input"), "direction": .string("input")])
                ]))
        #expect(r.error == nil)
        #expect(e.settingsManager.preferredInputDeviceUID == "fixture-input")
        #expect(e.settingsManager.lockedInputDeviceUID == "fixture-input")
    }

    @Test func inactiveMultiRoutingRemainsDiscoverable() async {
        let e = makeAutomationEngine()
        let service = AutomationService(engine: e)
        _ = await service.execute(
            .init(
                id: "multi", method: "app.routing.set",
                params: [
                    "target": .object(["appId": .string("com.test.multi")]), "mode": .string("multi"),
                    "deviceUIDs": .array([.string("offline-a"), .string("offline-b")]),
                    "allowOffline": .bool(true),
                ]))
        let apps = await service.execute(.init(id: "list", method: "app.list"))
        #expect(
            apps.result?.object?["apps"]?.array?.contains { $0.object?["appId"] == .string("com.test.multi") }
                == true)
        let routing = service.snapshot().object?["state"]?.object?["routing"]?.array?.first {
            $0.object?["appId"] == .string("com.test.multi")
        }
        #expect(routing?.object?["mode"] == .string("multi"))
    }

    @Test func activeOfflineRoutePreservesEngineIntent() async {
        let app = automationApp(123459)
        let e = makeAutomationEngine(apps: [app])
        let service = AutomationService(engine: e)
        let r = await service.execute(
            .init(
                id: "offline", method: "app.routing.set",
                params: [
                    "target": .object(["appId": .string("com.test.player")]), "mode": .string("single"),
                    "deviceUIDs": .array([.string("offline-speaker")]), "allowOffline": .bool(true),
                ]))
        #expect(r.result?.object?["status"] == .string("stored"))
        #expect(e.getDeviceUID(for: app) == "offline-speaker")
    }

}
