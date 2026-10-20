import XCTest
import Observation
import Darwin
@testable import FineTune

@Observable
@MainActor
private final class FakeControlEngine: ControlEngine {
    var state: ControlJSON = .object(["value": .number(0)])
    var commands: [ControlCommand] = []
    var failure: ControlFailure?
    func controlState() -> ControlJSON { state }
    func performControlCommand(_ command: ControlCommand) throws {
        if let failure { throw failure }
        commands.append(command)
        state = .object(["value": .number(Double(commands.count))])
    }
}

@MainActor
private final class ControlServiceFixture {
    let engine = FakeControlEngine()
    var messages: [UUID: [ControlJSON]] = [:]
    var closed: [UUID] = []
    var scheduled: [@MainActor () -> Void] = []
    var holdResponses = false
    var sent: [@MainActor () -> Void] = []
    lazy var service = ControlService(
        engine: engine,
        send: { [weak self] data, id, completed in
            do {
                let value = try JSONDecoder().decode(ControlJSON.self, from: data)
                self?.messages[id, default: []].append(value)
                if self?.holdResponses == true, value.object?["type"] == .string("response") {
                    self?.sent.append(completed)
                } else { completed() }
            }
            catch { XCTFail("Invalid outbound JSON: \(error)") }
        },
        disconnect: { [weak self] in self?.closed.append($0) },
        schedule: { [weak self] action in
            self?.scheduled.append(action)
            return Task {}
        }
    )

    func connect() -> UUID {
        if service.sessionID.isEmpty { service.start(listen: false) }
        let id = UUID()
        service.connected(id, session: service.sessionID)
        return id
    }

    func request(_ method: String, id requestID: String, client: UUID, params: [String: ControlJSON] = [:], session: String? = nil) throws {
        let value = ControlJSON.object([
            "type": .string("request"), "id": .string(requestID),
            "sessionId": .string(session ?? service.sessionID), "method": .string(method), "params": .object(params)
        ])
        service.received(try JSONEncoder().encode(value), from: client, session: service.sessionID)
    }

    func runPublication() {
        let actions = scheduled
        scheduled.removeAll()
        for action in actions { action() }
    }
}

nonisolated final class ControlServiceTests: XCTestCase {
    @MainActor
    func testHelloSubscribeDedupFlushAndSessionReset() throws {
        let f = ControlServiceFixture()
        let id = f.connect()
        defer { f.service.stop() }
        XCTAssertEqual(f.messages[id]?.first?.object?["protocol"], .string("finetune-control"))
        XCTAssertEqual(f.messages[id]?.first?.object?["version"], .number(1))
        try f.request("subscribe", id: "1", client: id)
        XCTAssertEqual(f.messages[id]?.last?.object?["result"]?.object?["revision"], .number(0))
        f.engine.state = .object(["value": .number(2)])
        try f.request("getState", id: "2", client: id)
        XCTAssertEqual(f.service.revision, 1)
        XCTAssertEqual(f.messages[id]?.last?.object?["result"]?.object?["state"], f.engine.state)
        f.service.flush()
        XCTAssertEqual(f.service.revision, 1)
        let session = f.service.sessionID
        f.service.stop()
        f.service.start(listen: false)
        XCTAssertNotEqual(f.service.sessionID, session)
        XCTAssertEqual(f.service.revision, 0)
    }

    @MainActor
    func testSubscribeResponsePrecedesEventsAndCommandResponse() throws {
        let f = ControlServiceFixture()
        let id = f.connect()
        defer { f.service.stop() }
        f.engine.state = .object(["value": .number(7)])
        try f.request("subscribe", id: "1", client: id)
        XCTAssertEqual(f.messages[id]?.count, 2)
        XCTAssertEqual(f.messages[id]?.last?.object?["type"], .string("response"))
        try f.request("setAppMute", id: "2", client: id, params: ["appId": .string("a"), "muted": .bool(true)])
        XCTAssertEqual(f.engine.commands, [.mute("a", nil, true)])
        f.service.flush()
        let messages = try XCTUnwrap(f.messages[id])
        XCTAssertEqual(messages[messages.count - 2].object?["result"], .object(["accepted": .bool(true)]))
        XCTAssertEqual(messages.last?.object?["type"], .string("event"))
        f.engine.state = .object(["value": .number(9)])
        try f.request("subscribe", id: "3", client: id)
        XCTAssertEqual(f.messages[id]?.count, messages.count + 1)
    }

    @MainActor
    func testObservationRearmsWithoutRestartingPublicationWindow() async throws {
        let f = ControlServiceFixture()
        let id = f.connect()
        defer { f.service.stop() }
        try f.request("subscribe", id: "1", client: id)
        f.engine.state = .object(["value": .number(1)])
        await nextMainTurn()
        XCTAssertEqual(f.scheduled.count, 1)
        f.engine.state = .object(["value": .number(2)])
        await nextMainTurn()
        XCTAssertEqual(f.scheduled.count, 1)
        f.runPublication()
        XCTAssertEqual(f.service.revision, 1)
        XCTAssertEqual(f.messages[id]?.last?.object?["state"], f.engine.state)
        f.engine.state = .object(["value": .number(3)])
        await nextMainTurn()
        XCTAssertEqual(f.scheduled.count, 1)
        f.runPublication()
        XCTAssertEqual(f.service.revision, 2)
    }

    @MainActor
    func testErrorsAndCompletedIDReuse() throws {
        let f = ControlServiceFixture()
        let id = f.connect()
        defer { f.service.stop() }
        try f.request("getState", id: "1", client: id, session: "old")
        XCTAssertEqual(f.messages[id]?.last?.object?["error"]?.object?["code"], .string("staleSession"))
        for (index, code) in ["appNotFound", "ambiguousApp", "staleApp", "deviceNotFound", "unsupportedRouting", "permissionDenied", "commandFailed", "internalError"].enumerated() {
            f.engine.failure = ControlFailure(code: code, message: "Test failure")
            try f.request("setPreferredInput", id: "error\(index)", client: id, params: ["deviceUID": .string("mic")])
            XCTAssertEqual(f.messages[id]?.last?.object?["error"]?.object?["code"], .string(code))
        }
        try f.request("unknown", id: "method", client: id)
        XCTAssertEqual(f.messages[id]?.last?.object?["error"]?.object?["code"], .string("unknownMethod"))
        try f.request("setAppMute", id: "params", client: id)
        XCTAssertEqual(f.messages[id]?.last?.object?["error"]?.object?["code"], .string("invalidParams"))
        try f.request("getState", id: "1", client: id)
        XCTAssertTrue(f.closed.isEmpty)
        XCTAssertNotNil(f.messages[id]?.last?.object?["result"])
        XCTAssertEqual(f.service.pendingRequestCount, 0)
    }

    @MainActor
    func testDuplicateInFlightIDDisconnectsAndCompletedHistoryDoesNotGrow() throws {
        let f = ControlServiceFixture()
        let id = f.connect()
        defer { f.service.stop() }
        for index in 0..<10_000 {
            try f.request("getState", id: String(index), client: id)
            XCTAssertEqual(f.service.pendingRequestCount, 0)
            f.messages[id]?.removeAll()
        }
        f.holdResponses = true
        try f.request("getState", id: "held", client: id)
        XCTAssertEqual(f.service.pendingRequestCount, 1)
        try f.request("getState", id: "held", client: id)
        XCTAssertEqual(f.closed, [id])
        XCTAssertEqual(f.service.pendingRequestCount, 0)
        for completed in f.sent { completed() }
        XCTAssertEqual(f.service.pendingRequestCount, 0)
    }

    @MainActor
    func testMalformedInputAndUnencodableStateDisconnect() {
        let f = ControlServiceFixture()
        let id = f.connect()
        defer { f.service.stop() }
        f.service.received(Data("not json".utf8), from: id, session: f.service.sessionID)
        XCTAssertEqual(f.closed, [id])
        let other = f.connect()
        f.engine.state = .number(.nan)
        f.service.flush()
        XCTAssertNoThrow(try f.request("getState", id: "state", client: other))
        XCTAssertTrue(f.closed.contains(other))
    }

    @MainActor
    func testSettingObservationDefaultOffEnableDisableAndReenable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ft-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = SettingsManager(directory: root)
        let directory = root.appendingPathComponent("FineTune/Control")
        let server = UnixSocketServer(directory: directory)
        let firstReady = expectation(description: "First listener ready")
        let secondReady = expectation(description: "Second listener ready")
        var starts = 0
        let service = ControlService(engine: FakeControlEngine(), settings: settings, server: server, onReady: {
            starts += 1
            if starts == 1 { firstReady.fulfill() } else { secondReady.fulfill() }
        })
        addTeardownBlock {
            await withCheckedContinuation { continuation in
                Task { @MainActor in service.stop { continuation.resume() } }
            }
            await MainActor.run { settings.flushSync() }
            try? FileManager.default.removeItem(at: root)
        }
        service.observeSetting()
        XCTAssertEqual(service.sessionID, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        settings.appSettings.externalControlEnabled = true
        let firstResult = await XCTWaiter.fulfillment(of: [firstReady], timeout: 3)
        XCTAssertEqual(firstResult, .completed)
        XCTAssertNil(service.startupFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        let firstSession = service.sessionID
        let (firstFD, firstHello) = try await socketHello(directory)
        defer { close(firstFD) }
        XCTAssertEqual(firstHello.object?["type"], .string("hello"))
        XCTAssertEqual(firstHello.object?["sessionId"], .string(firstSession))
        settings.appSettings.externalControlEnabled = false
        let firstClosed = await socketClosed(firstFD)
        XCTAssertTrue(firstClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        settings.appSettings.externalControlEnabled = true
        let secondResult = await XCTWaiter.fulfillment(of: [secondReady], timeout: 3)
        XCTAssertEqual(secondResult, .completed)
        XCTAssertNil(service.startupFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        XCTAssertNotEqual(service.sessionID, firstSession)
        let (secondFD, secondHello) = try await socketHello(directory)
        defer { close(secondFD) }
        XCTAssertEqual(secondHello.object?["sessionId"], .string(service.sessionID))
        settings.appSettings.externalControlEnabled = false
        let secondClosed = await socketClosed(secondFD)
        XCTAssertTrue(secondClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
    }

    private func socketHello(_ directory: URL) async throws -> (Int32, ControlJSON) {
        try await Task.detached {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(directory.appendingPathComponent("control.sock").path.utf8) + [0]
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.ENFILE) }
            do {
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                    throw POSIXError(.EINVAL)
                }
                var data = Data()
                var byte: UInt8 = 0
                while Darwin.read(fd, &byte, 1) == 1 {
                    if byte == 10 { return (fd, try JSONDecoder().decode(ControlJSON.self, from: data)) }
                    data.append(byte)
                }
                throw POSIXError(.ETIMEDOUT)
            } catch { close(fd); throw error }
        }.value
    }

    private func socketClosed(_ fd: Int32) async -> Bool {
        await Task.detached {
            var byte: UInt8 = 0
            return Darwin.read(fd, &byte, 1) == 0
        }.value
    }

    @MainActor
    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
