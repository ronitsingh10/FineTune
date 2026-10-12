import Foundation

@MainActor
final class EQAutomationAdapter: AutomationAdapter {
    let stateKey = "eq"
    let engine: AudioEngine
    let apps: AppAutomationAdapter
    init(engine: AudioEngine, apps: AppAutomationAdapter) {
        self.engine = engine
        self.apps = apps
    }
    var descriptors: [AutomationDescriptor] {
        let t = AutomationField(name: "target", type: "target", source: "apps")
        let b = AutomationField(name: "band", type: "number", minimum: 0, maximum: 9)
        return [
            .init(
                method: "app.eq.setEnabled", title: "Enable App EQ",
                fields: [t, .init(name: "enabled", type: "boolean")]),
            .init(method: "app.eq.toggle", title: "Toggle App EQ", fields: [t]),
            .init(
                method: "app.eq.band.set", title: "Set EQ Band",
                fields: [t, b, .init(name: "gainDB", type: "number", minimum: -12, maximum: 12)]),
            .init(
                method: "app.eq.band.step", title: "Step EQ Band",
                fields: [t, b, .init(name: "delta", type: "number", minimum: -24, maximum: 24)],
                dialParameter: "delta", units: "dB"),
            .init(
                method: "app.eq.setBands", title: "Set EQ Bands",
                fields: [t, .init(name: "bandGains", type: "bands")]),
            .init(method: "app.eq.reset", title: "Reset App EQ", fields: [t]),
            .init(
                method: "app.eq.preset.apply", title: "Apply EQ Preset",
                fields: [t, .init(name: "presetId", type: "string", source: "eqPresets")]),
            .init(method: "eq.preset.list", title: "List EQ Presets", fields: []),
            .init(
                method: "eq.preset.create", title: "Save EQ Preset",
                fields: [.init(name: "name", type: "string"), .init(name: "bandGains", type: "bands")]),
            .init(
                method: "eq.preset.rename", title: "Rename EQ Preset",
                fields: [
                    .init(name: "presetId", type: "string", source: "userPresets"),
                    .init(name: "name", type: "string"),
                ]),
            .init(
                method: "eq.preset.delete", title: "Delete EQ Preset",
                fields: [.init(name: "presetId", type: "string", source: "userPresets")], destructive: true),
        ]
    }
    func bands(_ value: AutomationValue?) throws -> [Float] {
        guard let list = value?.array, list.count == 10 else {
            throw AutomationError(.invalidParameter, "Exactly ten bands required", field: "bandGains")
        }
        return try list.map {
            guard let n = $0.number, n.isFinite, (-12...12).contains(n) else {
                throw AutomationError(.invalidParameter, "Band must be -12 to +12 dB", field: "bandGains")
            }
            return Float(n)
        }
    }
    func snapshot() -> AutomationValue {
        .object([
            "presets": .array(
                EQPreset.allCases.map {
                    .object([
                        "id": .string($0.rawValue), "name": .string($0.name),
                        "bandGains": .array($0.settings.bandGains.map { .number(Double($0)) }),
                        "builtin": .bool(true),
                    ])
                }
                    + engine.settingsManager.getUserPresets().map {
                        .object([
                            "id": .string($0.id.uuidString), "name": .string($0.name),
                            "bandGains": .array($0.settings.bandGains.map { .number(Double($0)) }),
                            "builtin": .bool(false),
                        ])
                    }),
            "apps": .array(
                engine.settingsManager.automationKnownAppIdentifiers.union(
                    engine.apps.map(\.persistenceIdentifier)
                ).sorted().map { id in
                    .object([
                        "appId": .string(id),
                        "eq": (try? .encode(engine.getEQSettingsForInactive(identifier: id))) ?? .null,
                    ])
                }),
        ])
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        let p = AutomationParameters(params)
        let settings = engine.settingsManager
        if method == "eq.preset.list" { return snapshot() }
        if method == "eq.preset.create" {
            let name = try p.string("name")
            let values = try bands(params["bandGains"])
            let preset = settings.createUserPreset(name: name, settings: EQSettings(bandGains: values))
            return .object(["status": .string("stored"), "preset": try .encode(preset)])
        }
        if method == "eq.preset.rename" || method == "eq.preset.delete" {
            let raw = try p.string("presetId")
            guard let uuid = UUID(uuidString: raw),
                settings.getUserPresets().contains(where: { $0.id == uuid })
            else { throw AutomationError(.notFound, "User preset unavailable") }
            if method == "eq.preset.delete" {
                settings.deleteUserPreset(id: uuid)
            } else {
                let name = try p.string("name")
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AutomationError(.invalidParameter, "Preset name is empty")
                }
                settings.updateUserPreset(id: uuid, name: name)
            }
            return .object(["status": .string("stored"), "state": snapshot()])
        }
        let (id, active) = try apps.resolve(AutomationTarget.parse(params["target"]))
        guard !engine.isIgnored(identifier: id) else { throw AutomationError(.unavailable, "App is ignored") }
        var eq =
            active.first.map { engine.getEQSettings(for: $0) }
            ?? engine.getEQSettingsForInactive(identifier: id)
        switch method {
        case "app.eq.setEnabled": eq.isEnabled = try p.bool("enabled")
        case "app.eq.toggle": eq.isEnabled.toggle()
        case "app.eq.band.set", "app.eq.band.step":
            let index = try p.integer("band", values: Array(0..<10))
            let gain =
                method == "app.eq.band.set"
                ? try p.number("gainDB", range: -12...12)
                : max(-12, min(12, Double(eq.bandGains[index]) + (try p.number("delta", range: -24...24))))
            eq.bandGains[index] = Float(gain)
        case "app.eq.setBands": eq.bandGains = try bands(params["bandGains"])
        case "app.eq.reset": eq = .flat
        case "app.eq.preset.apply":
            let presetId = try p.string("presetId")
            if let preset = EQPreset(rawValue: presetId) {
                eq = preset.settings
            } else if let preset = settings.getUserPresets().first(where: { $0.id.uuidString == presetId }) {
                eq = preset.settings
            } else {
                throw AutomationError(.notFound, "EQ preset unavailable")
            }
        default: throw AutomationError(.unknownMethod, "Unknown EQ operation")
        }
        if active.isEmpty { engine.setEQSettingsForInactive(eq, identifier: id) }
        let applied = active.map { engine.setEQSettings(eq, for: $0) }
        return .object([
            "status": .string(!applied.isEmpty && applied.allSatisfy { $0 } ? "applied" : "stored"),
            "state": try .encode(eq),
        ])
    }
}
