import AppKit
import Foundation

@MainActor
final class PresentationAutomationAdapter: AutomationAdapter {
    let stateKey = "presentation"
    let engine: AudioEngine
    let popup: PopupVisibilityService
    let controller: any MenuBarPopupControlling
    var openSettings: (() -> Void)?
    init(engine: AudioEngine, popup: PopupVisibilityService, controller: any MenuBarPopupControlling) {
        self.engine = engine
        self.popup = popup
        self.controller = controller
    }
    var descriptors: [AutomationDescriptor] {
        ["show", "hide", "toggle"].map {
            .init(method: "ui.popup.\($0)", title: "\($0.capitalized) FineTune", fields: [])
        } + [
            .init(method: "ui.settings.open", title: "Open FineTune Settings", fields: []),
            .init(
                method: "ui.eq.open", title: "Open App EQ",
                fields: [.init(name: "target", type: "target", source: "apps")]),
            .init(
                method: "ui.deviceInspector.open", title: "Open Device Inspector",
                fields: [.init(name: "target", type: "target", source: "devices")]),
            .init(
                method: "ui.editMode.set", title: "Set Edit Mode",
                fields: [.init(name: "enabled", type: "boolean")]),
            .init(
                method: "ui.deviceTab.set", title: "Select Device Tab",
                fields: [.init(name: "tab", type: "string", choices: ["input", "output"])]),
            .init(
                method: "device.uid.copy", title: "Copy Device UID",
                fields: [.init(name: "target", type: "target", source: "devices")]),
            .init(method: "ui.permissionSettings.open", title: "Open macOS Audio Permissions", fields: []),
            .init(method: "ui.help.open", title: "Open FineTune Help", fields: []),
        ]
    }
    func snapshot() -> AutomationValue {
        .object([
            "popupVisible": .bool(popup.isVisible), "editMode": .bool(popup.isEditingDevicePriority),
            "deviceTab": .string(popup.showingInputDevices ? "input" : "output"),
            "eqAppId": popup.expandedRowID.map { .string($0) } ?? .null,
            "inspectorDeviceUID": popup.expandedDeviceUID.map { .string($0) } ?? .null,
        ])
    }
    func show(_ desired: Bool) async throws {
        if popup.isVisible != desired { controller.toggle() }
        for _ in 0..<20 {
            if popup.isVisible == desired { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AutomationError(.unavailable, "Popup did not reach requested state")
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        let p = AutomationParameters(params)
        switch method {
        case "ui.popup.show": try await show(true)
        case "ui.popup.hide": try await show(false)
        case "ui.popup.toggle": try await show(!popup.isVisible)
        case "ui.editMode.set":
            popup.isEditingDevicePriority = try p.bool("enabled")
            try await show(true)
        case "ui.deviceTab.set":
            popup.showingInputDevices = try p.choice("tab", ["input", "output"]) == "input"
            try await show(true)
        case "ui.eq.open":
            guard case .app(let id, _) = try AutomationTarget.parse(params["target"]),
                engine.displayableApps.contains(where: { $0.id == id })
            else { throw AutomationError(.unavailable, "App is not visible; pin it first") }
            popup.expandedRowID = id
            try await show(true)
        case "ui.deviceInspector.open", "device.uid.copy":
            let (device, direction) = try DeviceAutomationAdapter(engine: engine).resolve(
                AutomationTarget.parse(params["target"]))
            if method == "device.uid.copy" {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.uid, forType: .string)
            } else {
                guard direction == "output" else {
                    throw AutomationError(.unavailable, "FineTune has no input device inspector panel")
                }
                try await show(true)
                if popup.showingInputDevices {
                    popup.showingInputDevices = false
                    try await Task.sleep(for: .milliseconds(50))
                }
                popup.isEditingDevicePriority = true
                popup.expandedDeviceUID = device.uid
            }
        case "ui.settings.open":
            if openSettings == nil { try await show(true) }
            if let openSettings {
                openSettings()
            } else {
                guard NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) else {
                    throw AutomationError(.unavailable, "Settings action not ready")
                }
            }
        case "ui.permissionSettings.open":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case "ui.help.open":
            NSWorkspace.shared.open(
                URL(string: "https://github.com/ronitsingh10/FineTune/blob/main/guide/troubleshooting.md")!)
        default: throw AutomationError(.unknownMethod, "Unknown presentation operation")
        }
        return .object(["status": .string("applied"), "state": snapshot()])
    }
}
