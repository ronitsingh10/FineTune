import AppKit
import Foundation
import Testing

@testable import FineTune

@Suite("Automation catalog") @MainActor
struct AutomationCatalogTests {
    @Test func catalogIsConsumableAndExportsPublicFixture() async throws {
        let e = makeAutomationEngine(apps: [automationApp(12345, id: "com.example.player")])
        let devices = e.deviceMonitor as! MockAudioDeviceMonitor
        devices.addOutputDevice(
            .init(
                id: 100001, uid: "fixture-output", name: "Fixture Speakers", icon: NSImage(),
                supportsAutoEQ: true))
        devices.inputDevices = [
            .init(
                id: 100002, uid: "fixture-input", name: "Fixture Microphone", icon: NSImage(),
                supportsAutoEQ: false)
        ]
        let service = AutomationService(engine: e)
        let visibility = PopupVisibilityService()
        service.adapters.append(
            PresentationAutomationAdapter(
                engine: e, popup: visibility, controller: AutomationTestPopupController(visibility)))
        let names = service.allDescriptors.map(\.method)
        #expect(names.count == Set(names).count)
        let supported = Set([
            "target", "number", "boolean", "string", "strings", "bands", "profileText", "preferences",
            "commands",
        ])
        for descriptor in service.allDescriptors {
            #expect(descriptor.fields.allSatisfy { supported.contains($0.type) })
        }
        let description = await service.execute(.init(id: "catalog", method: "api.describe"))
        var fixture = description.result?.object ?? [:]
        fixture["status"] = .string("ready")
        fixture["message"] = .string("Ready")
        var snapshot = service.snapshot().object?["state"]?.object ?? [:]
        // Use no user's imported AutoEQ profiles in the shared contract fixture.
        snapshot["autoeq"] = .object([
            "profiles": .array([]), "devices": .array([]), "favorites": .array([]),
            "preampEnabled": .bool(true),
        ])
        fixture["snapshot"] = .object(snapshot)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ft-automation-catalog-\(UUID().uuidString).json")
        try JSONEncoder().encode(AutomationValue.object(fixture)).write(to: file)
        print("Automation catalog fixture: \(file.path)")
    }
}
