import Foundation

@MainActor
protocol AutomationAdapter: AnyObject {
    var stateKey: String { get }
    var descriptors: [AutomationDescriptor] { get }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue
    func snapshot() -> AutomationValue
}

/// Transport-independent command boundary. Never called from an audio callback.
@MainActor
final class AutomationService {
    let engine: AudioEngine
    let appAdapter: AppAutomationAdapter
    let operations = AutomationOperationStore()
    var adapters: [any AutomationAdapter]
    let instanceId = UUID().uuidString
    private(set) var revision = 0
    private var lastState: AutomationValue = .null
    init(engine: AudioEngine, resolver: (any TargetAppResolving)? = nil) {
        self.engine = engine
        let adapter = AppAutomationAdapter(engine: engine, resolver: resolver)
        self.appAdapter = adapter
        self.adapters = [
            adapter, DeviceAutomationAdapter(engine: engine),
            RoutingAutomationAdapter(engine: engine, apps: adapter),
            EQAutomationAdapter(engine: engine, apps: adapter),
            PreferencesAutomationAdapter(engine: engine, apps: adapter),
            AutoEQAutomationAdapter(engine: engine), BluetoothAutomationAdapter(engine: engine),
            UpdateAutomationAdapter(),
        ]
    }
    var allDescriptors: [AutomationDescriptor] {
        [
            .init(method: "api.describe", title: "API Capabilities", fields: []),
            .init(method: "state.get", title: "Full State", fields: []),
            .init(method: "events.subscribe", title: "Subscribe to Changes", fields: []),
            .init(
                method: "operation.get", title: "Operation Result",
                fields: [.init(name: "operationId", type: "string")]),
            .init(
                method: "batch.execute", title: "Run Scene",
                fields: [
                    .init(name: "commands", type: "commands"),
                    .init(name: "continueOnError", type: "boolean", required: false),
                ]),
        ] + adapters.flatMap(\.descriptors)
    }
    func snapshot() -> AutomationValue {
        var sections = Dictionary(uniqueKeysWithValues: adapters.map { ($0.stateKey, $0.snapshot()) })
        sections["operations"] = operations.snapshot()
        sections["resolvedAppId"] =
            (try? appAdapter.resolve(.selector("audibleApp")).0).map { .string($0) } ?? .null
        let data = AutomationValue.object(sections)
        if data != lastState {
            revision += 1
            lastState = data
        }
        return .object([
            "instanceId": .string(instanceId), "revision": .number(Double(revision)), "state": data,
        ])
    }
    func execute(_ request: AutomationRequest) async -> AutomationResponse {
        do {
            try request.validate()
            if request.params["expectedRevision"] != nil {
                _ = snapshot()
                let expected = try AutomationParameters(request.params).number(
                    "expectedRevision", range: 0...9_007_199_254_740_991)
                guard expected.rounded() == expected, expected == Double(revision) else {
                    throw AutomationError(.conflict, "State changed since this command was prepared")
                }
            }
            let result: AutomationValue
            switch request.method {
            case "api.describe":
                result = .object([
                    "apiVersion": .number(1), "instanceId": .string(instanceId),
                    "methods": try .encode(allDescriptors),
                ])
            case "state.get", "events.subscribe": result = snapshot()
            case "operation.get":
                result = try operations.get(AutomationParameters(request.params).string("operationId"))
            case "batch.execute":
                guard let commands = request.params["commands"]?.array, commands.count <= 64 else {
                    throw AutomationError(.invalidParameter, "Batch supports at most 64 commands")
                }
                let validated = try commands.map { command -> AutomationRequest in
                    guard let o = command.object, let method = o["method"]?.string, method != "batch.execute",
                        method != "events.subscribe", let params = o["params"]?.object
                    else { throw AutomationError(.invalidParameter, "Invalid batch command") }
                    let request = AutomationRequest(id: UUID().uuidString, method: method, params: params)
                    try request.validate()
                    return request
                }
                let id = try operations.start(resource: "batch:" + UUID().uuidString) {
                    var outcomes: [AutomationValue] = []
                    for command in validated {
                        try Task.checkCancellation()
                        let outcome = await self.execute(command)
                        var encoded = try AutomationValue.encode(outcome)
                        var failed = outcome.error != nil
                        if let operationId = outcome.result?.object?["operationId"]?.string,
                            outcome.result?.object?["status"] == .string("pending")
                        {
                            let terminal = try await self.operations.wait(operationId)
                            var object: [String: AutomationValue] = [
                                "apiVersion": .number(1), "id": .string(command.id),
                            ]
                            if let error = terminal.object?["error"] {
                                object["error"] = error
                                failed = true
                            } else {
                                object["result"] = terminal.object?["result"] ?? .null
                            }
                            encoded = .object(object)
                        }
                        outcomes.append(encoded)
                        if failed && request.params["continueOnError"]?.bool != true { break }
                    }
                    return .object(["results": .array(outcomes)])
                }
                result = .object(["status": .string("pending"), "operationId": .string(id)])
            default:
                guard
                    let adapter = adapters.first(where: {
                        $0.descriptors.contains(where: { $0.method == request.method })
                    })
                else { throw AutomationError(.unknownMethod, "Unknown automation method") }
                let target = request.params["target"]?.object
                var resource =
                    target?["appId"]?.string.map { "app:" + $0 } ?? target?["deviceUID"]?.string.map {
                        "device:" + $0
                    } ?? request.params["profileId"]?.string ?? request.params["bluetoothId"]?.string
                    ?? (request.method.hasPrefix("alert.") ? "alert" : request.method)
                if target?["selector"]?.string == "audibleApp",
                    let resolved = try? appAdapter.resolve(.selector("audibleApp"))
                {
                    resource = "app:" + resolved.0
                }
                if let selector = target?["selector"]?.string,
                    selector == "defaultInput" || selector == "defaultOutput"
                {
                    resource =
                        "device:"
                        + ((selector == "defaultInput"
                            ? engine.deviceVolumeMonitor.defaultInputDeviceUID
                            : engine.deviceVolumeMonitor.defaultDeviceUID) ?? "missing")
                }
                let readOnly =
                    request.method.hasSuffix(".get") || request.method.hasSuffix(".list")
                    || request.method.hasSuffix(".status")
                if !readOnly && operations.isBusy(resource) {
                    throw AutomationError(.busy, "Resource has an in-flight operation")
                }
                let routingAsync =
                    try (adapter as? RoutingAutomationAdapter)?.requiresAsync(request.params) ?? false
                let deviceAsync =
                    try (adapter as? DeviceAutomationAdapter)?.requiresAsync(
                        method: request.method, params: request.params) ?? false
                if routingAsync || deviceAsync
                    || [
                        "autoeq.get", "autoeq.device.select", "bluetooth.connect", "alert.volume.set",
                        "alert.volume.step",
                    ].contains(request.method)
                {
                    let id = try operations.start(resource: resource) {
                        try await adapter.execute(method: request.method, params: request.params)
                    }
                    result = .object(["status": .string("pending"), "operationId": .string(id)])
                } else {
                    result = try await adapter.execute(method: request.method, params: request.params)
                }
            }
            _ = snapshot()
            var object = result.object ?? ["value": result]
            object["revision"] = .number(Double(revision))
            object["instanceId"] = .string(instanceId)
            return .init(id: request.id, result: .object(object))
        } catch let error as AutomationError { return .init(id: request.id, error: error) } catch {
            return .init(id: request.id, error: .init(.internalError, "Automation operation failed"))
        }
    }
}
