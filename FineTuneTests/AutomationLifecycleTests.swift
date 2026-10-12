import Foundation
import Testing

@testable import FineTune

@Suite("Automation lifecycle") @MainActor
struct AutomationLifecycleTests {
    @Test func socketRoundTripAndOwnedCleanup() async throws {
        let e = makeAutomationEngine()
        let service = AutomationService(engine: e)
        let broker = AutomationStateBroker(service: service)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let discovery = root.appendingPathComponent("discovery.json")
        let server = AutomationSocketServer(
            handler: { await service.execute($0) }, subscription: { await broker.subscribe() })
        try server.start(discoveryURL: discovery, instanceId: service.instanceId)
        defer {
            server.stop()
            broker.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let socketPath = try JSONDecoder().decode(AutomationDiscovery.self, from: Data(contentsOf: discovery))
            .socketPath
        let reply = try await Task.detached {
            let p = Process()
            let output = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [
                "-c",
                "import socket,json,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); s.sendall(b'{\"apiVersion\":1,\"id\":\"socket-test\",\"method\":\"state.get\",\"params\":{}}\\n'); print(s.makefile().readline())",
                socketPath,
            ]
            p.standardOutput = output
            p.standardError = Pipe()
            try p.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return try JSONDecoder().decode(AutomationResponse.self, from: data)
        }.value
        #expect(reply.id == "socket-test")
        #expect(reply.result?.object?["state"]?.object?["apps"]?.array == [])
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: discovery.path))
    }
    @Test func optInStartsAndDisableRevokes() async throws {
        let e = makeAutomationEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = AutomationRuntime(
            engine: e, resolver: nil, popup: PopupVisibilityService(),
            controller: AutomationTestPopupController(PopupVisibilityService()),
            discoveryURL: root.appendingPathComponent("discovery.json"))
        runtime.reconcile()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("discovery.json").path))
        var prefs = e.settingsManager.appSettings
        prefs.automationEnabled = true
        e.settingsManager.appSettings = prefs
        runtime.reconcile()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("discovery.json").path))
        prefs.automationEnabled = false
        e.settingsManager.appSettings = prefs
        runtime.reconcile()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("discovery.json").path))
        runtime.stop()
        try? FileManager.default.removeItem(at: root)
    }
    @Test func resetDisablesAndRemovesDiscovery() async throws {
        let e = makeAutomationEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = root.appendingPathComponent("discovery.json")
        let visibility = PopupVisibilityService()
        let runtime = AutomationRuntime(
            engine: e, resolver: nil, popup: visibility,
            controller: AutomationTestPopupController(visibility), discoveryURL: path)
        defer {
            runtime.stop()
            try? FileManager.default.removeItem(at: root)
        }
        var prefs = e.settingsManager.appSettings
        prefs.automationEnabled = true
        e.settingsManager.appSettings = prefs
        #expect(FileManager.default.fileExists(atPath: path.path))
        _ = await runtime.service.execute(.init(id: "reset", method: "settings.reset"))
        // Parallel hosted UI tests can occupy MainActor; check eventual owned cleanup.
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: path.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!e.settingsManager.appSettings.automationEnabled)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func secondInstanceCannotReplaceLiveDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = root.appendingPathComponent("discovery.json")
        let first = AutomationSocketServer(
            handler: { .init(id: $0.id, result: .object([:])) }, subscription: { AsyncStream { $0.finish() } }
        )
        let second = AutomationSocketServer(
            handler: { .init(id: $0.id, result: .object([:])) }, subscription: { AsyncStream { $0.finish() } }
        )
        defer {
            second.stop()
            first.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try first.start(discoveryURL: path, instanceId: "first")
        #expect(throws: AutomationError.self) { try second.start(discoveryURL: path, instanceId: "second") }
        #expect(
            try JSONDecoder().decode(AutomationDiscovery.self, from: Data(contentsOf: path)).instanceId
                == "first")
    }

}
