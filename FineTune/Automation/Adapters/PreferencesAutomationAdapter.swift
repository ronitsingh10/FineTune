import Foundation
import KeyboardShortcuts

@MainActor
final class PreferencesAutomationAdapter: AutomationAdapter {
    let stateKey = "preferences"
    let engine: AudioEngine
    let apps: AppAutomationAdapter
    var registry: ShortcutsRegistry?
    init(engine: AudioEngine, apps: AppAutomationAdapter) {
        self.engine = engine
        self.apps = apps
    }
    static let allowed = [
        "launchAtLogin", "menuBarIconStyle", "defaultNewAppVolume", "lockInputDevice",
        "showDeviceDisconnectAlerts", "loudnessCompensationEnabled", "loudnessEqualizationEnabled",
        "hudStyle", "mediaKeyControlEnabled", "volumeHotkeyStep", "appearance", "popupSize",
    ]
    var descriptors: [AutomationDescriptor] {
        let t = AutomationField(name: "target", type: "target", source: "apps")
        return [
            .init(method: "preferences.get", title: "Read Preferences", fields: []),
            .init(
                method: "preferences.patch", title: "Set FineTune Preferences",
                fields: [.init(name: "settings", type: "preferences")]),
            .init(
                method: "loudness.set", title: "Set Loudness",
                fields: [
                    .init(name: "enabled", type: "boolean", required: false),
                    .init(name: "compensation", type: "boolean", required: false),
                    .init(name: "equalization", type: "boolean", required: false),
                ]),
            .init(
                method: "app.pin.set", title: "Pin App", fields: [t, .init(name: "pinned", type: "boolean")]),
            .init(
                method: "app.ignore.set", title: "Ignore App",
                fields: [t, .init(name: "ignored", type: "boolean")]),
            .init(method: "shortcut.list", title: "Read Shortcuts", fields: []),
            .init(
                method: "shortcut.set", title: "Set Shortcut",
                fields: [
                    .init(name: "action", type: "string", choices: ShortcutAction.allCases.map(\.rawValue)),
                    .init(name: "keyCode", type: "number", minimum: 0, maximum: 127),
                    .init(name: "modifiers", type: "number", minimum: 0, maximum: 65535),
                ]),
            .init(
                method: "shortcut.clear", title: "Clear Shortcut",
                fields: [
                    .init(name: "action", type: "string", choices: ShortcutAction.allCases.map(\.rawValue))
                ]),
            .init(
                method: "settings.reset", title: "Reset All FineTune Settings", fields: [], destructive: true),
        ]
    }
    func snapshot() -> AutomationValue { (try? .encode(engine.settingsManager.appSettings)) ?? .null }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        let p = AutomationParameters(params)
        let settings = engine.settingsManager
        if method == "preferences.get" { return snapshot() }
        if method == "shortcut.list" {
            return .object([
                "shortcuts": (try? .encode(settings.appSettings.customShortcuts)) ?? .null,
                "actions": .array(
                    ShortcutAction.allCases.map {
                        .object(["id": .string($0.rawValue), "name": .string($0.displayName)])
                    }),
            ])
        }
        if method == "app.pin.set" || method == "app.ignore.set" {
            let (id, active) = try apps.resolve(AutomationTarget.parse(params["target"]))
            if method == "app.pin.set" {
                if try p.bool("pinned") {
                    guard !engine.isIgnored(identifier: id) else {
                        throw AutomationError(.unavailable, "Restore ignored app before pinning")
                    }
                    if let app = active.first {
                        engine.pinApp(app)
                    } else {
                        settings.pinApp(
                            id,
                            info: .init(
                                persistenceIdentifier: id, displayName: id,
                                bundleID: id.hasPrefix("name:") ? nil : id))
                    }
                } else {
                    engine.unpinApp(id)
                }
            } else {
                if try p.bool("ignored") {
                    if active.isEmpty {
                        settings.ignoreApp(
                            id,
                            info: .init(
                                persistenceIdentifier: id, displayName: id,
                                bundleID: id.hasPrefix("name:") ? nil : id))
                    }
                    for app in active { engine.ignoreApp(app) }
                } else {
                    engine.unignoreApp(id)
                }
            }
            return .object(["status": .string("stored"), "state": apps.snapshot()])
        }
        if method == "settings.reset" {
            settings.resetAllSettings()
            engine.handleSettingsReset()
            return .object(["status": .string("applied")])
        }
        if method.hasPrefix("shortcut.") {
            guard let registry else { throw AutomationError(.unavailable, "Shortcut service is not ready") }
            let action = ShortcutAction(
                rawValue: try p.choice("action", ShortcutAction.allCases.map(\.rawValue)))!
            var value = settings.appSettings
            if method == "shortcut.clear" {
                value.customShortcuts[action.rawValue] = nil
                KeyboardShortcuts.setShortcut(nil, for: registry.name(for: action))
            } else {
                let code = try p.integer("keyCode", values: Array(0...127))
                let modifiers = try p.number("modifiers", range: 0...65535)
                guard modifiers.rounded() == modifiers else {
                    throw AutomationError(.invalidParameter, "Modifiers must be an integer")
                }
                let chord = ShortcutCodable(keyCode: code, modifiers: UInt(modifiers))
                guard
                    !value.customShortcuts.contains(where: { $0.key != action.rawValue && $0.value == chord })
                else { throw AutomationError(.conflict, "Shortcut already used by another FineTune action") }
                KeyboardShortcuts.setShortcut(chord.keyboardShortcut, for: registry.name(for: action))
                value.customShortcuts[action.rawValue] = chord
            }
            settings.appSettings = value
            return .object(["status": .string("applied"), "state": snapshot()])
        }
        var value = settings.appSettings
        if method == "loudness.set" {
            guard params["enabled"] != nil || params["compensation"] != nil || params["equalization"] != nil
            else { throw AutomationError(.invalidParameter, "Specify at least one loudness flag") }
            if params["enabled"] != nil { value.setUnifiedLoudnessEnabled(try p.bool("enabled")) }
            if params["compensation"] != nil {
                value.loudnessCompensationEnabled = try p.bool("compensation")
            }
            if params["equalization"] != nil {
                value.loudnessEqualizationEnabled = try p.bool("equalization")
            }
        } else if method == "preferences.patch" {
            guard let patch = params["settings"]?.object, !patch.isEmpty,
                Set(patch.keys).isSubset(of: Set(Self.allowed))
            else {
                throw AutomationError(
                    .invalidParameter, "Unknown or empty preference patch", field: "settings")
            }
            var merged = try AutomationValue.encode(value).object!
            for (key, v) in patch { merged[key] = v }
            do {
                value = try JSONDecoder().decode(
                    AppSettings.self, from: JSONEncoder().encode(AutomationValue.object(merged)))
            } catch {
                throw AutomationError(.invalidParameter, "Invalid preference value", field: "settings")
            }
            guard value.defaultNewAppVolume.isFinite, (0...1).contains(value.defaultNewAppVolume) else {
                throw AutomationError(.invalidParameter, "Default volume must be 0...1")
            }
        } else {
            throw AutomationError(.unknownMethod, "Unknown preference operation")
        }
        settings.appSettings = value
        return .object(["status": .string("applied"), "state": snapshot()])
    }
}
