import Foundation
import Testing

@testable import FineTune

@Suite("AutoEQ automation") @MainActor
struct AutomationAutoEQTests {
    @Test func disconnectedOutputAfterProfileLoadCannotReportApplied() async {
        let e = makeAutomationEngine()
        let devices = e.deviceMonitor as! MockAudioDeviceMonitor
        devices.addOutputDevice(
            .init(id: 123458, uid: "fixture-correction", name: "Headphones", icon: nil, supportsAutoEQ: true))
        let adapter = AutoEQAutomationAdapter(
            engine: e,
            loadProfile: { id in
                devices.outputDevices = []
                return AutoEQProfile(id: id, name: "Fixture", source: .imported, preampDB: 0, filters: [])
            })
        var unavailable = false
        do {
            _ = try await adapter.execute(
                method: "autoeq.device.select",
                params: [
                    "target": .object(["deviceUID": .string("fixture-correction")]),
                    "profileId": .string("fixture"),
                ])
        } catch let error as AutomationError { unavailable = error.code == .unavailable } catch {}
        #expect(unavailable)
        #expect(e.getAutoEQSelection(for: "fixture-correction") == nil)
    }
    @Test func currentOutputSelectorResolvesAtExecution() async {
        let e = makeAutomationEngine()
        let devices = e.deviceMonitor as! MockAudioDeviceMonitor
        devices.addOutputDevice(
            .init(
                id: 123458, uid: "fixture-correction", name: "Fixture Headphones", icon: nil,
                supportsAutoEQ: true))
        (e.deviceVolumeMonitor as! MockDeviceVolumeProviding).defaultDeviceUID = "fixture-correction"
        let r = await AutomationService(engine: e).execute(
            .init(
                id: "correction", method: "autoeq.device.clear",
                params: ["target": .object(["selector": .string("defaultOutput")])]))
        #expect(r.error == nil)
    }
    @Test func invalidImportDoesNotCreateAProfile() async {
        let e = makeAutomationEngine()
        let before = e.autoEQProfileManager.profiles.count
        let r = await AutomationService(engine: e).execute(
            .init(
                id: "import", method: "autoeq.import",
                params: ["name": .string("Fixture"), "text": .string("invalid")]))
        #expect(r.error?.code == .invalidParameter)
        #expect(e.autoEQProfileManager.profiles.count == before)
    }
}
