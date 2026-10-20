import XCTest
import Darwin
@testable import FineTune

private nonisolated final class SocketTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func readAndAdvance() -> TimeInterval { lock.withLock { defer { value += 11 }; return value } }
}

private nonisolated final class SocketNamespaceSwap: @unchecked Sendable {
    private let lock = NSLock()
    private var performed = false

    func once(_ action: () throws -> Void) rethrows {
        try lock.withLock {
            guard !performed else { return }
            performed = true
            try action()
        }
    }
}

nonisolated final class UnixSocketServerTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ft-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("FineTune/Control")
    }

    private func start(_ server: UnixSocketServer, frame: @escaping @Sendable (UUID, Data) -> Void = { _, _ in },
                       connected: @escaping @Sendable (UUID) -> Void = { _ in },
                       disconnected: @escaping @Sendable (UUID) -> Void = { _ in }) async {
        let ready = expectation(description: "Listener ready")
        server.start(onConnect: connected, onFrame: { id, data, completed in frame(id, data); completed() }, onDisconnect: disconnected,
                     onFailure: { message in XCTFail(message); ready.fulfill() }, onReady: { ready.fulfill() })
        await fulfillment(of: [ready], timeout: 3)
        addTeardownBlock {
            await withCheckedContinuation { continuation in server.stop { continuation.resume() } }
        }
    }

    private nonisolated func connect(_ directory: URL) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(directory.appendingPathComponent("control.sock").path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlFailure(code: "testPath", message: "Temporary socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        return fd
    }

    func testFragmentedCoalescedAndCRLFFrames() async throws {
        let directory = try makeDirectory()
        let server = UnixSocketServer(directory: directory)
        let first = expectation(description: "Fragmented first frame")
        let second = expectation(description: "Coalesced second frame")
        await start(server, frame: { _, data in
            if data == Data("{\"a\":1}".utf8) { first.fulfill() }
            else if data == Data("{\"b\":2}".utf8) { second.fulfill() }
            else { XCTFail("Unexpected frame") }
        })
        let fd = try connect(directory)
        defer { close(fd) }
        let prefix = Data("{\"a\":".utf8)
        let suffix = Data("1}\r\n{\"b\":2}\n".utf8)
        XCTAssertEqual(prefix.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, prefix.count) }, prefix.count)
        XCTAssertEqual(suffix.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, suffix.count) }, suffix.count)
        await fulfillment(of: [first, second], timeout: 3)
    }

    func testInvalidEmptyAndOversizedFramesClose() async throws {
        for payload in [Data([10]), Data([0xff, 10]), Data(repeating: 65, count: UnixSocketServer.maximumFrameBytes + 1)] {
            let directory = try makeDirectory()
            let server = UnixSocketServer(directory: directory)
            let closed = expectation(description: "Invalid client closed")
            await start(server, frame: { _, _ in XCTFail("Invalid frame delivered") }, disconnected: { _ in closed.fulfill() })
            let fd = try connect(directory)
            _ = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, payload.count) }
            await fulfillment(of: [closed], timeout: 3)
            close(fd)
        }
    }

    func testPeerRejectionBeforeParsing() async throws {
        let directory = try makeDirectory()
        let checked = expectation(description: "Peer checked")
        let rejecting = UnixSocketServer(directory: directory, peerUID: { _ in checked.fulfill(); return geteuid() + 1 })
        await start(rejecting, frame: { _, _ in XCTFail("Unauthorized frame parsed") }, connected: { _ in XCTFail("Unauthorized peer accepted") })
        let fd = try connect(directory)
        defer { close(fd) }
        await fulfillment(of: [checked], timeout: 3)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(fd, &byte, 1), 0)
    }

    func testPermissionsLockContentionAndCleanup() async throws {
        let directory = try makeDirectory()
        let server = UnixSocketServer(directory: directory)
        await start(server)
        var info = stat()
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let path = directory.appendingPathComponent("control.sock").path
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let inode = info.st_ino
        let second = UnixSocketServer(directory: directory)
        let failed = expectation(description: "Second instance refused")
        second.start(onConnect: { _ in XCTFail() }, onFrame: { _, _, completed in XCTFail(); completed() }, onDisconnect: { _ in }, onFailure: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_ino, inode)
        let fd = try connect(directory)
        close(fd)
        await withCheckedContinuation { continuation in server.stop { continuation.resume() } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("server.lock").path))
        await start(second)
    }

    func testRefusesSymlinkAndNonSocket() async throws {
        for symlink in [false, true] {
            let directory = try makeDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("control.sock")
            if symlink { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: directory) }
            else { try Data("do not remove".utf8).write(to: path) }
            let server = UnixSocketServer(directory: directory)
            let failed = expectation(description: "Unsafe socket refused")
            server.start(onConnect: { _ in XCTFail() }, onFrame: { _, _, completed in XCTFail(); completed() }, onDisconnect: { _ in }, onFailure: { _ in failed.fulfill() })
            await fulfillment(of: [failed], timeout: 3)
            var info = stat()
            XCTAssertEqual(lstat(path.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, symlink ? S_IFLNK : S_IFREG)
        }
    }

    func testPartialFrameTimeoutUsesInjectedClock() async throws {
        let directory = try makeDirectory()
        let clock = SocketTestClock()
        let server = UnixSocketServer(directory: directory, now: { clock.readAndAdvance() })
        let closed = expectation(description: "Partial frame timed out")
        await start(server, disconnected: { _ in closed.fulfill() })
        let fd = try connect(directory)
        defer { close(fd) }
        var byte: UInt8 = 123
        XCTAssertEqual(Darwin.write(fd, &byte, 1), 1)
        await fulfillment(of: [closed], timeout: 3)
    }

    func testOutboundQueueBoundsAndStalledWriter() async throws {
        for (frameCount, size, stalled) in [(1, 1_048_576, true), (10, 1_048_576, false), (20, 32_768, false)] {
            let directory = try makeDirectory()
            let clock = SocketTestClock()
            let server = UnixSocketServer(directory: directory, now: { stalled ? clock.readAndAdvance() : ProcessInfo.processInfo.systemUptime })
            let closed = expectation(description: "Slow output client disconnected")
            let payload = Data(repeating: 65, count: size)
            await start(server, connected: { id in
                for _ in 0..<frameCount { server.send(payload, to: id) }
            }, disconnected: { _ in closed.fulfill() })
            let fd = try connect(directory)
            defer { close(fd) }
            await fulfillment(of: [closed], timeout: 3)
        }
    }

    func testPartialWritesPreserveCompleteFrame() async throws {
        let directory = try makeDirectory()
        let server = UnixSocketServer(directory: directory)
        let payload = Data(repeating: 65, count: 512_000)
        await start(server, connected: { id in server.send(payload, to: id) })
        let fd = try connect(directory)
        defer { close(fd) }
        let received = await Task.detached {
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while result.count < payload.count + 1 {
                let count = Darwin.read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                result.append(contentsOf: chunk.prefix(count))
            }
            return result
        }.value
        XCTAssertEqual(received, payload + Data([10]))
    }

    func testClientLimit() async throws {
        let directory = try makeDirectory()
        let server = UnixSocketServer(directory: directory)
        let connected = expectation(description: "Eight accepted clients")
        connected.expectedFulfillmentCount = 8
        await start(server, connected: { _ in connected.fulfill() })
        var descriptors: [Int32] = []
        defer { for fd in descriptors { close(fd) } }
        for _ in 0..<8 { descriptors.append(try connect(directory)) }
        await fulfillment(of: [connected], timeout: 3)
        let extra = try connect(directory)
        defer { close(extra) }
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(extra, &byte, 1), 0)
    }

    private func bindSocket(_ directory: URL) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(directory.appendingPathComponent("control.sock").path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        return fd
    }

    func testStaleSocketRecoveryAndReplacementIdentity() async throws {
        let directory = try makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = try bindSocket(directory)
        close(stale)
        let server = UnixSocketServer(directory: directory)
        await start(server)
        let path = directory.appendingPathComponent("control.sock").path
        XCTAssertEqual(unlink(path), 0)
        let replacement = try bindSocket(directory)
        defer { close(replacement) }
        var before = stat()
        XCTAssertEqual(lstat(path, &before), 0)
        await withCheckedContinuation { continuation in server.stop { continuation.resume() } }
        var after = stat()
        XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
    }

    func testRepairsOnlyControlPermissionsAndRejectsDirectorySymlinks() async throws {
        let directory = try makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = directory.deletingLastPathComponent()
        XCTAssertEqual(chmod(parent.path, 0o755), 0)
        XCTAssertEqual(chmod(directory.path, 0o777), 0)
        let server = UnixSocketServer(directory: directory)
        await start(server)
        var info = stat()
        XCTAssertEqual(lstat(parent.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)

        let unsafe = try makeDirectory()
        try FileManager.default.createDirectory(at: unsafe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: directory)
        let rejecting = UnixSocketServer(directory: unsafe)
        let failed = expectation(description: "Directory symlink refused")
        rejecting.start(onConnect: { _ in XCTFail() }, onFrame: { _, _, completed in XCTFail(); completed() }, onDisconnect: { _ in }, onFailure: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 3)
    }

    func testInjectedFilesystemRejectsForeignDirectoryAndSocketOwners() async throws {
        for foreignSocket in [false, true] {
            let directory = try makeDirectory()
            if foreignSocket {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                close(try bindSocket(directory))
            }
            let server = UnixSocketServer(directory: directory, fileStatus: { fd, name, info in
                let result = UnixSocketServer.readFileStatus(fd, name, info)
                var parent = stat()
                let isFineTune = lstat(directory.deletingLastPathComponent().path, &parent) == 0 &&
                    parent.st_dev == info.pointee.st_dev && parent.st_ino == info.pointee.st_ino
                if result == 0, foreignSocket ? name == "control.sock" : isFineTune { info.pointee.st_uid = geteuid() + 1 }
                return result
            })
            let failed = expectation(description: "Foreign ownership refused")
            server.start(onConnect: { _ in XCTFail() }, onFrame: { _, _, completed in XCTFail(); completed() },
                         onDisconnect: { _ in }, onFailure: { message in
                XCTAssertTrue(message.contains(foreignSocket ? "unsafe existing" : "belong to this user"))
                failed.fulfill()
            })
            await fulfillment(of: [failed], timeout: 3)
            if foreignSocket {
                var info = stat()
                XCTAssertEqual(lstat(directory.appendingPathComponent("control.sock").path, &info), 0)
                XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
            }
        }
    }

    func testRejectsWritableParentWithoutRepairingIt() async throws {
        let directory = try makeDirectory()
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o777), 0)
        let server = UnixSocketServer(directory: directory)
        let failed = expectation(description: "Writable parent refused")
        server.start(onConnect: { _ in XCTFail() }, onFrame: { _, _, completed in XCTFail(); completed() },
                     onDisconnect: { _ in }, onFailure: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 3)
        var info = stat()
        XCTAssertEqual(lstat(parent.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o777)
    }

    func testAcceptsMaximumFrameWithoutTruncation() async throws {
        let directory = try makeDirectory()
        let server = UnixSocketServer(directory: directory)
        let received = expectation(description: "Maximum payload delivered")
        await start(server, frame: { _, data in
            XCTAssertEqual(data.count, UnixSocketServer.maximumFrameBytes)
            received.fulfill()
        })
        let fd = try connect(directory)
        defer { close(fd) }
        let payload = Data(repeating: 65, count: UnixSocketServer.maximumFrameBytes) + Data([10])
        let count = await Task.detached {
            payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { break }
                    offset += written
                }
                return offset
            }
        }.value
        XCTAssertEqual(count, payload.count)
        await fulfillment(of: [received], timeout: 3)
    }

    func testRejectsWritableApplicationSupportAndHigherAncestorWithoutRepair() async throws {
        for higherAncestor in [false, true] {
            let original = try makeDirectory()
            let root = original.deletingLastPathComponent().deletingLastPathComponent()
            let directory = higherAncestor ? root.appendingPathComponent("Support/FineTune/Control") : original
            let support = directory.deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let unsafe = higherAncestor ? root : support
            XCTAssertEqual(chmod(unsafe.path, 0o777), 0)
            let server = UnixSocketServer(directory: directory)
            let failed = expectation(description: "Writable namespace ancestor refused")
            server.start(onConnect: { _ in XCTFail() }, onFrame: { _, _, done in XCTFail(); done() },
                         onDisconnect: { _ in }, onFailure: { message in
                XCTAssertTrue(message.contains("ancestors"))
                failed.fulfill()
            })
            await fulfillment(of: [failed], timeout: 3)
            var info = stat()
            XCTAssertEqual(lstat(unsafe.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o777)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        }
    }

    func testNamespaceSwapAfterValidationCleansActualBoundSocket() async throws {
        let directory = try makeDirectory()
        let parent = directory.deletingLastPathComponent()
        let moved = parent.deletingLastPathComponent().appendingPathComponent("Moved")
        let swap = SocketNamespaceSwap()
        let server = UnixSocketServer(directory: directory, fileStatus: { fd, name, info in
            let result = UnixSocketServer.readFileStatus(fd, name, info)
            let savedErrno = errno
            if name == "control.sock" {
                do {
                    try swap.once {
                        try FileManager.default.moveItem(at: parent, to: moved)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    }
                } catch { XCTFail("Cannot arrange namespace swap: \(error)") }
            }
            errno = savedErrno
            return result
        })
        let failed = expectation(description: "Namespace mismatch refused")
        server.start(onConnect: { _ in XCTFail() }, onFrame: { _, _, done in XCTFail(); done() },
                     onDisconnect: { _ in }, onFailure: { message in
            XCTAssertTrue(message.contains("inspect bound socket"))
            failed.fulfill()
        })
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Control/control.sock").path))
    }
}
