import Foundation

@MainActor
final class RoutingAutomationAdapter: AutomationAdapter {
    let stateKey = "routing"
    let engine: AudioEngine
    let apps: AppAutomationAdapter
    init(engine: AudioEngine, apps: AppAutomationAdapter) {
        self.engine = engine
        self.apps = apps
    }
    var descriptors: [AutomationDescriptor] {
        [
            .init(
                method: "app.routing.set", title: "Route App Audio",
                fields: [
                    .init(name: "target", type: "target", source: "apps"),
                    .init(name: "mode", type: "string", choices: ["followDefault", "single", "multi"]),
                    .init(name: "deviceUIDs", type: "strings", required: false, source: "outputs"),
                    .init(name: "allowOffline", type: "boolean", required: false),
                ])
        ]
    }
    func snapshot() -> AutomationValue {
        .array(
            engine.settingsManager.automationKnownAppIdentifiers.union(
                engine.apps.map(\.persistenceIdentifier)
            ).sorted().map { id in
                let active = engine.apps.filter { $0.persistenceIdentifier == id }
                let selection = engine.getDeviceSelectionModeForInactive(identifier: id)
                let following = selection == .single && engine.isFollowingDefaultForInactive(identifier: id)
                let single = selection == .single && !following ? engine.getDeviceRoutingForInactive(identifier: id) : nil
                let selected = selection == .multi ? engine.getSelectedDeviceUIDsForInactive(identifier: id).sorted() : [single].compactMap { $0 }
                return .object([
                    "appId": .string(id),
                    "mode": .string(selection == .multi ? "multi" : following ? "followDefault" : "single"),
                    "deviceUIDs": .array(selected.map { .string($0) }),
                    "singleDeviceUID": single.map { .string($0) } ?? .null,
                    "effectiveDeviceUIDs": .array(
                        active.flatMap { engine.automationEffectiveRouting(for: $0) }.map { .string($0) }),
                ])
            })
    }
    func requiresAsync(_ params: [String: AutomationValue]) throws -> Bool {
        let p = AutomationParameters(params)
        let (id, active) = try apps.resolve(AutomationTarget.parse(params["target"]))
        let mode = try p.choice("mode", ["followDefault", "single", "multi"])
        let uids = params["deviceUIDs"] == nil ? [] : try p.strings("deviceUIDs")
        guard Set(uids).count == uids.count, mode != "single" || uids.count == 1,
            mode != "multi" || !uids.isEmpty, mode != "followDefault" || uids.isEmpty
        else { throw AutomationError(.invalidParameter, "Invalid routing selection") }
        let missing = uids.contains { uid in !engine.outputDevices.contains { $0.uid == uid } }
        if missing && params["allowOffline"]?.bool != true {
            throw AutomationError(.unavailable, "Output device is disconnected")
        }
        guard !engine.isIgnored(identifier: id) else { throw AutomationError(.unavailable, "App is ignored") }
        return !active.isEmpty && !missing
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        let p = AutomationParameters(params)
        let (id, active) = try apps.resolve(AutomationTarget.parse(params["target"]))
        let mode = try p.choice("mode", ["followDefault", "single", "multi"])
        let uids = params["deviceUIDs"] == nil ? [] : try p.strings("deviceUIDs")
        guard Set(uids).count == uids.count, mode != "single" || uids.count == 1,
            mode != "multi" || !uids.isEmpty, mode != "followDefault" || uids.isEmpty
        else { throw AutomationError(.invalidParameter, "Invalid routing selection") }
        let missing = uids.contains { uid in !engine.outputDevices.contains { $0.uid == uid } }
        if missing && params["allowOffline"]?.bool != true {
            throw AutomationError(.unavailable, "Output device is disconnected")
        }
        guard !engine.isIgnored(identifier: id) else { throw AutomationError(.unavailable, "App is ignored") }
        let selection: DeviceSelectionMode = mode == "multi" ? .multi : .single
        if active.isEmpty {
            engine.setDeviceSelectionModeForInactive(identifier: id, to: selection)
            if mode == "multi" {
                engine.setSelectedDeviceUIDsForInactive(identifier: id, to: Set(uids))
            } else {
                engine.setDeviceRoutingForInactive(identifier: id, deviceUID: uids.first)
            }
            return .object(["status": .string("stored"), "state": snapshot()])
        }
        for app in active {
            engine.setDeviceSelectionMode(for: app, to: selection)
            if mode == "multi" {
                engine.setSelectedDeviceUIDs(for: app, to: Set(uids))
            } else {
                engine.setDevice(for: app, deviceUID: uids.first)
            }
        }
        if missing { return .object(["status": .string("stored"), "state": snapshot()]) }
        let expected = Set(
            mode == "followDefault" ? [engine.deviceVolumeMonitor.defaultDeviceUID].compactMap { $0 } : uids)
        for _ in 0..<100 {
            if active.allSatisfy({ Set(engine.automationEffectiveRouting(for: $0)) == expected }),
                !expected.isEmpty
            {
                return .object(["status": .string("applied"), "state": snapshot()])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AutomationError(.timeout, "Routing not confirmed; intended route is saved")
    }
}
