import Foundation

@MainActor
final class AutoEQAutomationAdapter: AutomationAdapter {
    let stateKey = "autoeq"
    let engine: AudioEngine
    private let loadProfile: @MainActor (String) async -> AutoEQProfile?
    init(engine: AudioEngine, loadProfile: (@MainActor (String) async -> AutoEQProfile?)? = nil) {
        self.engine = engine
        self.loadProfile = loadProfile ?? { await engine.autoEQProfileManager.resolveProfile(for: $0) }
    }
    var descriptors: [AutomationDescriptor] {
        let t = AutomationField(name: "target", type: "target", source: "outputs")
        let profile = AutomationField(name: "profileId", type: "string", source: "autoeq")
        return [
            .init(
                method: "autoeq.search", title: "Search AutoEQ",
                fields: [
                    .init(name: "query", type: "string"),
                    .init(name: "limit", type: "number", required: false, minimum: 1, maximum: 100),
                ]),
            .init(method: "autoeq.list", title: "List Loaded AutoEQ Profiles", fields: []),
            .init(method: "autoeq.get", title: "Get AutoEQ Profile", fields: [profile]),
            .init(
                method: "autoeq.device.select", title: "Select Headphone Correction", fields: [t, profile]),
            .init(method: "autoeq.device.clear", title: "Clear Headphone Correction", fields: [t]),
            .init(
                method: "autoeq.device.setEnabled", title: "Enable Headphone Correction",
                fields: [t, .init(name: "enabled", type: "boolean")]),
            .init(
                method: "autoeq.preamp.set", title: "Set AutoEQ Preamp Compensation",
                fields: [.init(name: "enabled", type: "boolean")]),
            .init(
                method: "autoeq.favorite.set", title: "Favorite AutoEQ Profile",
                fields: [profile, .init(name: "favorite", type: "boolean")]),
            .init(
                method: "autoeq.import", title: "Import Headphone Correction",
                fields: [.init(name: "name", type: "string"), .init(name: "text", type: "profileText")]),
            .init(
                method: "autoeq.deleteImported", title: "Delete Imported Correction",
                fields: [.init(name: "profileId", type: "string", source: "importedProfiles")],
                destructive: true),
        ]
    }
    func snapshot() -> AutomationValue {
        .object([
            "profiles":
                (try? .encode(Array(engine.autoEQProfileManager.profiles.values).sorted { $0.id < $1.id }))
                ?? .null,
            "favorites": .array(engine.settingsManager.favoriteAutoEQProfileIDs.sorted().map { .string($0) }),
            "preampEnabled": .bool(engine.autoEQPreampEnabled),
            "devices": .array(
                engine.outputDevices.map {
                    .object([
                        "deviceUID": .string($0.uid),
                        "selection": (try? .encode(engine.getAutoEQSelection(for: $0.uid))) ?? .null,
                    ])
                }),
        ])
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        let p = AutomationParameters(params)
        let manager = engine.autoEQProfileManager
        switch method {
        case "autoeq.list": return snapshot()
        case "autoeq.search":
            let limit = params["limit"] == nil ? 50 : try p.integer("limit", values: Array(1...100))
            let result = manager.search(query: try p.string("query"), limit: limit)
            return .object([
                "entries": try .encode(result.entries), "totalCount": .number(Double(result.totalCount)),
            ])
        case "autoeq.get":
            guard let profile = await manager.resolveProfile(for: try p.string("profileId")) else {
                throw AutomationError(.notFound, "AutoEQ profile unavailable")
            }
            return try .encode(profile)
        case "autoeq.import":
            let name = try p.string("name")
            guard let text = params["text"]?.string, text.utf8.count <= 250_000,
                AutoEQParser.parse(text: text, name: name, source: .imported) != nil
            else { throw AutomationError(.invalidParameter, "Invalid or oversized ParametricEQ text") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let profile = manager.importProfile(from: url, name: name) else {
                throw AutomationError(.unavailable, "Could not import profile")
            }
            return .object(["status": .string("stored"), "profile": try .encode(profile)])
        case "autoeq.deleteImported":
            let id = try p.string("profileId")
            guard manager.profiles[id]?.source == .imported else {
                throw AutomationError(.notFound, "Imported profile unavailable")
            }
            manager.deleteImportedProfile(id: id)
        case "autoeq.favorite.set":
            let id = try p.string("profileId")
            guard manager.catalogEntry(for: id) != nil || manager.profiles[id] != nil else {
                throw AutomationError(.notFound, "Profile unavailable")
            }
            if try p.bool("favorite") {
                engine.settingsManager.favoriteAutoEQProfile(id: id)
            } else {
                engine.settingsManager.unfavoriteAutoEQProfile(id: id)
            }
        case "autoeq.preamp.set": engine.setAutoEQPreampEnabled(try p.bool("enabled"))
        case "autoeq.device.select", "autoeq.device.clear", "autoeq.device.setEnabled":
            let (device, direction) = try DeviceAutomationAdapter(engine: engine).resolve(
                AutomationTarget.parse(params["target"]))
            guard direction == "output", device.supportsAutoEQ else {
                throw AutomationError(.unavailable, "Correction-capable output required")
            }
            let uid = device.uid
            if method == "autoeq.device.clear" {
                engine.setAutoEQProfile(for: uid, profileID: nil)
            } else if method == "autoeq.device.setEnabled" {
                guard engine.getAutoEQSelection(for: uid) != nil else {
                    throw AutomationError(.unavailable, "No correction selected")
                }
                engine.setAutoEQEnabled(for: uid, enabled: try p.bool("enabled"))
            } else {
                let id = try p.string("profileId")
                guard await loadProfile(id) != nil else {
                    throw AutomationError(.unavailable, "Correction profile could not load")
                }
                try Task.checkCancellation()
                guard engine.outputDevices.contains(where: { $0.uid == uid && $0.supportsAutoEQ }) else {
                    throw AutomationError(
                        .unavailable, "Selected output disconnected while loading correction")
                }
                engine.setAutoEQProfile(for: uid, profileID: id)
            }
        default: throw AutomationError(.unknownMethod, "Unknown AutoEQ operation")
        }
        return .object(["status": .string("applied"), "state": snapshot()])
    }
}
