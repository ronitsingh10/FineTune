import Foundation
import Testing

@testable import FineTune

@Suite("Automation operations") @MainActor
struct AutomationOperationTests {
    @Test func batchStopsAtError() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let commands: AutomationValue = .array([
            .object([
                "method": .string("app.volume.set"),
                "params": .object([
                    "target": .object(["appId": .string("com.test.player")]), "percent": .number(20),
                ]),
            ]),
            .object(["method": .string("bad.method"), "params": .object([:])]),
            .object([
                "method": .string("app.volume.set"),
                "params": .object([
                    "target": .object(["appId": .string("com.test.player")]), "percent": .number(80),
                ]),
            ]),
        ])
        let r = await s.execute(.init(id: "1", method: "batch.execute", params: ["commands": commands]))
        let result = try? await s.operations.wait(r.result?.object?["operationId"]?.string ?? "")
        #expect(result?.object?["result"]?.object?["results"]?.array?.count == 2)
        #expect(e.settingsManager.getVolume(for: "com.test.player") == 0.2)
    }
    @Test func sceneWaitsForAsyncFailureBeforeLaterMutations() async throws {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let commands: AutomationValue = .array([
            .object([
                "method": .string("autoeq.get"),
                "params": .object(["profileId": .string("nonexistent-fixture")]),
            ]),
            .object([
                "method": .string("app.volume.set"),
                "params": .object([
                    "target": .object(["appId": .string("com.test.player")]), "percent": .number(80),
                ]),
            ]),
        ])
        var r = await s.execute(.init(id: "scene", method: "batch.execute", params: ["commands": commands]))
        if let id = r.result?.object?["operationId"]?.string {
            for _ in 0..<100 {
                let op = try s.operations.get(id)
                if op.object?["status"] != .string("pending") {
                    r = .init(id: "scene", result: op.object?["result"] ?? .null)
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(r.result?.object?["results"]?.array?.count == 1)
        #expect(r.result?.object?["results"]?.array?.first?.object?["error"] != nil)
        #expect(e.settingsManager.getVolume(for: "com.test.player") == nil)
    }
    @Test func sceneWaitsForSameResourceBeforeNextCommand() async throws {
        let e = makeAutomationEngine(); let s = AutomationService(engine: e)
        s.adapters.insert(DelayedSceneAdapter(), at: 0)
        let target: AutomationValue = .object(["appId": .string("com.test.player")])
        let commands: AutomationValue = .array([
            .object(["method": .string("alert.volume.set"), "params": .object(["target": target])]),
            .object(["method": .string("app.volume.set"), "params": .object(["target": target, "percent": .number(80)])])
        ])
        let r = await s.execute(.init(id: "scene", method: "batch.execute", params: ["commands": commands]))
        let result = try await s.operations.wait(try #require(r.result?.object?["operationId"]?.string))
        let rows = try #require(result.object?["result"]?.object?["results"]?.array)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.object?["error"] == nil })
        #expect(e.settingsManager.getVolume(for: "com.test.player") == 0.8)
    }
    @Test func asyncFailureCanBeQueried() async throws {
        let s = AutomationService(engine: makeAutomationEngine())
        let r = await s.execute(
            .init(id: "1", method: "autoeq.get", params: ["profileId": .string("nonexistent-fixture")]))
        #expect(r.result?.object?["status"] == .string("pending"))
        let id = try #require(r.result?.object?["operationId"]?.string)
        for _ in 0..<20 {
            let result = await s.execute(
                .init(id: "2", method: "operation.get", params: ["operationId": .string(id)]))
            if result.result?.object?["status"] == .string("failed") {
                #expect(result.result?.object?["error"]?.object?["code"] == .string("not_found"))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Async failure was not recorded")
    }
    @Test func metadataIncludesControlFamilies() async throws {
        let s = AutomationService(engine: makeAutomationEngine())
        let r = await s.execute(.init(id: "1", method: "api.describe"))
        let methods = try #require(r.result?.object?["methods"]?.array).compactMap {
            $0.object?["method"]?.string
        }
        for required in [
            "bluetooth.connect", "update.status", "batch.execute", "operation.get", "autoeq.import",
            "settings.reset",
        ] { #expect(methods.contains(required)) }
        #expect(Set(methods).count == methods.count)
    }
    @Test func malformedBatchCannotExecuteEarlierCommands() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let commands: AutomationValue = .array([
            .object([
                "method": .string("app.volume.set"),
                "params": .object([
                    "target": .object(["appId": .string("com.test.player")]), "percent": .number(20),
                ]),
            ]), .object(["method": .string("app.mute.set")]),
        ])
        let r = await s.execute(
            .init(id: "bad-batch", method: "batch.execute", params: ["commands": commands]))
        #expect(r.error?.code == .invalidParameter)
        #expect(e.settingsManager.getVolume(for: "com.test.player") == nil)
    }
    @Test func staleRevisionCannotOverwriteExternalChange() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let revision = s.snapshot().object?["revision"] ?? .number(0)
        e.settingsManager.setVolume(for: "com.test.player", to: 0.3)
        let r = await s.execute(
            .init(
                id: "stale", method: "app.volume.set",
                params: [
                    "target": .object(["appId": .string("com.test.player")]), "percent": .number(80),
                    "expectedRevision": revision,
                ]))
        #expect(r.error?.code == .conflict)
        #expect(e.settingsManager.getVolume(for: "com.test.player") == 0.3)
    }

}

@MainActor private final class DelayedSceneAdapter: AutomationAdapter {
    let stateKey = "sceneFixture"
    let descriptors: [AutomationDescriptor] = [.init(method: "alert.volume.set", title: "Fixture", fields: [])]
    func snapshot() -> AutomationValue { .null }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        try await Task.sleep(for: .milliseconds(25))
        return .object(["status": .string("applied")])
    }
}
