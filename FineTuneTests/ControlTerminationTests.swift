import XCTest
@testable import FineTune

nonisolated final class ControlTerminationTests: XCTestCase {
    @MainActor
    func testCleanupCompletionRepliesOnceAndCancelsFallback() async {
        var timeout: (@MainActor () -> Void)?
        var cleanup: (@Sendable () -> Void)?
        var replies = 0
        let termination = ControlTermination(schedule: { action in timeout = action; return Task {} })
        termination.begin(stop: { cleanup = $0 }, reply: { replies += 1 })
        XCTAssertEqual(replies, 0)
        cleanup?()
        await nextMainTurn()
        XCTAssertEqual(replies, 1)
        timeout?()
        cleanup?()
        await nextMainTurn()
        XCTAssertEqual(replies, 1)
    }

    @MainActor
    func testHungCleanupFallsBackAndLateOrRepeatedCompletionsCannotReplyTwice() async {
        var timeout: (@MainActor () -> Void)?
        var cleanup: (@Sendable () -> Void)?
        var schedules = 0
        var replies = 0
        let termination = ControlTermination(schedule: { action in
            schedules += 1
            timeout = action
            return Task {}
        })
        termination.begin(stop: { cleanup = $0 }, reply: { replies += 1 })
        termination.begin(stop: { _ in XCTFail("Stopped twice") }, reply: { XCTFail("Second reply") })
        XCTAssertEqual(schedules, 1)
        timeout?()
        XCTAssertEqual(replies, 1)
        cleanup?()
        cleanup?()
        timeout?()
        await nextMainTurn()
        XCTAssertEqual(replies, 1)
    }

    @MainActor
    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}
