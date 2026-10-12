import Testing

@testable import FineTune

@MainActor final class AutomationTestPopupController: MenuBarPopupControlling {
    let visibility: PopupVisibilityService
    init(_ visibility: PopupVisibilityService) { self.visibility = visibility }
    func toggle() { visibility.isVisible.toggle() }
}
@Suite("Presentation automation") @MainActor
struct AutomationPresentationTests {
    @Test func showIsIdempotentAndEditTabShareState() async throws {
        let engine = makeAutomationEngine()
        let visibility = PopupVisibilityService()
        let adapter = PresentationAutomationAdapter(
            engine: engine, popup: visibility, controller: AutomationTestPopupController(visibility))
        _ = try await adapter.execute(method: "ui.popup.show", params: [:])
        _ = try await adapter.execute(method: "ui.popup.show", params: [:])
        #expect(visibility.isVisible)
        _ = try await adapter.execute(method: "ui.deviceTab.set", params: ["tab": .string("input")])
        #expect(visibility.showingInputDevices)
        _ = try await adapter.execute(method: "ui.editMode.set", params: ["enabled": .bool(true)])
        #expect(visibility.isEditingDevicePriority)
        _ = try await adapter.execute(method: "ui.popup.hide", params: [:])
        #expect(!visibility.isVisible)
    }
}
