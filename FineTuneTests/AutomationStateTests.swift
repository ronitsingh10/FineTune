import Testing

@testable import FineTune

@Suite("Automation state") @MainActor
struct AutomationStateTests {
    @Test func subscriptionBeginsWithSnapshotAndTracksUIWrites() async throws {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let broker = AutomationStateBroker(service: s)
        var stream = broker.subscribe().makeAsyncIterator()
        let initial = try #require(await stream.next())
        let revision = try #require(initial.object?["revision"]?.number)
        e.settingsManager.setVolume(for: "com.test.external", to: 0.25)
        broker.reconcile()
        let next = try #require(await stream.next())
        #expect(next.object?["revision"]?.number ?? 0 > revision)
        #expect(next.object?["state"]?.object?["apps"]?.array?.first?.object?["volumePercent"] == .number(25))
        #expect(initial.object?["instanceId"] == next.object?["instanceId"])
        broker.stop()
    }
    @Test func unchangedSnapshotKeepsRevision() {
        let s = AutomationService(engine: makeAutomationEngine())
        #expect(s.snapshot() == s.snapshot())
    }
}
