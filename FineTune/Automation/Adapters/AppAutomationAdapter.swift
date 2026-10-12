import Foundation

@MainActor
final class AppAutomationAdapter: AutomationAdapter {
    let stateKey = "apps"
    let engine: AudioEngine
    let resolver: (any TargetAppResolving)?
    init(engine: AudioEngine, resolver: (any TargetAppResolving)? = nil) {
        self.engine = engine
        self.resolver = resolver
    }
    var descriptors: [AutomationDescriptor] {
        let target = AutomationField(name: "target", type: "target", source: "apps")
        return [
            .init(method: "app.list", title: "List Apps", fields: []),
            .init(method: "app.get", title: "App State", fields: [target]),
            .init(
                method: "app.volume.set", title: "Set App Volume",
                fields: [target, .init(name: "percent", type: "number", minimum: 0, maximum: 100)],
                units: "gain %"),
            .init(
                method: "app.volume.step", title: "Step App Volume",
                fields: [
                    target, .init(name: "domain", type: "string", choices: ["slider", "percent"]),
                    .init(name: "delta", type: "number", minimum: -100, maximum: 100),
                ], dialParameter: "delta", units: "%"),
            .init(
                method: "app.mute.set", title: "Set App Mute",
                fields: [target, .init(name: "muted", type: "boolean")]),
            .init(method: "app.mute.toggle", title: "Toggle App Mute", fields: [target]),
            .init(
                method: "app.boost.set", title: "Set App Boost",
                fields: [target, .init(name: "boost", type: "number", minimum: 1, maximum: 4)]),
            .init(method: "app.boost.cycle", title: "Cycle App Boost", fields: [target]),
            .init(method: "app.audio.reset", title: "Reset App Volume and Mute", fields: [target]),
        ]
    }
    func resolve(_ target: AutomationTarget) throws -> (String, [AudioApp]) {
        let id: String
        let pid: Int32?
        switch target {
        case .app(let value, let instance):
            id = value
            pid = instance
        case .selector("audibleApp"):
            guard let resolver,
                let selected = resolver.resolveTargetBundleID(
                    audibleCandidates: engine.apps.compactMap {
                        engine.isAudibleNow(bundleID: $0.bundleID ?? "") ? $0.bundleID : nil
                    })
            else { throw AutomationError(.unavailable, "No target app") }
            id = selected
            pid = nil
        default: throw AutomationError(.invalidParameter, "App target required", field: "target")
        }
        let matching = engine.apps.filter { $0.persistenceIdentifier == id && (pid == nil || $0.id == pid) }
        if pid != nil && matching.isEmpty { throw AutomationError(.notFound, "Runtime app is unavailable") }
        return (id, matching)
    }
    func state(_ id: String, apps: [AudioApp]) -> AutomationValue {
        let first = apps.first
        let volume = first.map { engine.getVolume(for: $0) } ?? engine.getVolumeForInactive(identifier: id)
        let boost = first.map { engine.getBoost(for: $0) } ?? engine.getBoostForInactive(identifier: id)
        let muted = first.map { engine.getMute(for: $0) } ?? engine.getMuteForInactive(identifier: id)
        let mixed = apps.contains { engine.getVolume(for: $0) != volume || engine.getMute(for: $0) != muted || engine.getBoost(for: $0) != boost }
        return .object([
            "appId": .string(id), "mixed": .bool(mixed), "name": .string(first?.name ?? id), "active": .bool(!apps.isEmpty),
            "instanceIds": .array(apps.map { .number(Double($0.id)) }),
            "volumePercent": .number(Double(volume) * 100),
            "sliderPercent": .number(VolumeMapping.gainToSlider(volume) * 100),
            "boost": .number(Double(boost.rawValue)), "muted": .bool(muted),
            "pinned": .bool(engine.isPinned(identifier: id)),
            "ignored": .bool(engine.isIgnored(identifier: id)),
        ])
    }
    func snapshot() -> AutomationValue {
        let ids = Set(engine.apps.map(\.persistenceIdentifier)).union(
            engine.settingsManager.automationKnownAppIdentifiers)
        return .array(
            ids.sorted().map { id in state(id, apps: engine.apps.filter { $0.persistenceIdentifier == id }) })
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        if method == "app.list" { return .object(["apps": snapshot()]) }
        let p = AutomationParameters(params)
        let (id, apps) = try resolve(AutomationTarget.parse(params["target"]))
        if method == "app.get" { return state(id, apps: apps) }
        if engine.isIgnored(identifier: id) {
            throw AutomationError(.unavailable, "App is ignored by FineTune")
        }
        func setVolume(_ value: Float) {
            if apps.isEmpty { engine.setVolumeForInactive(identifier: id, to: value) }
            for app in apps { engine.setVolume(for: app, to: value) }
        }
        func setMute(_ value: Bool) {
            if apps.isEmpty { engine.setMuteForInactive(identifier: id, to: value) }
            for app in apps { engine.setMute(for: app, to: value) }
        }
        switch method {
        case "app.volume.set": setVolume(Float(try p.number("percent", range: 0...100) / 100))
        case "app.volume.step":
            let delta = try p.number("delta", range: -100...100) / 100
            let domain = try p.choice("domain", ["slider", "percent"])
            let current =
                apps.first.map { engine.getVolume(for: $0) } ?? engine.getVolumeForInactive(identifier: id)
            let next =
                domain == "slider"
                ? VolumeMapping.sliderToGain(max(0, min(1, VolumeMapping.gainToSlider(current) + delta)))
                : Float(max(0, min(1, Double(current) + delta)))
            if delta > 0 { setMute(false) }
            setVolume(next)
        case "app.mute.set": setMute(try p.bool("muted"))
        case "app.mute.toggle":
            setMute(
                !(apps.first.map { engine.getMute(for: $0) } ?? engine.getMuteForInactive(identifier: id)))
        case "app.boost.set", "app.boost.cycle":
            let current =
                apps.first.map { engine.getBoost(for: $0) } ?? engine.getBoostForInactive(identifier: id)
            let next =
                method == "app.boost.cycle"
                ? current.next : BoostLevel(rawValue: Float(try p.integer("boost", values: [1, 2, 3, 4])))!
            if apps.isEmpty { engine.setBoostForInactive(identifier: id, to: next) }
            for app in apps { engine.setBoost(for: app, to: next) }
        case "app.audio.reset":
            setVolume(1)
            setMute(false)
        default: throw AutomationError(.unknownMethod, "Unknown app operation")
        }
        return .object([
            "status": .string(apps.isEmpty ? "stored" : "applied"), "state": state(id, apps: apps),
        ])
    }
}
