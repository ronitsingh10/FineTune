import Darwin
import Foundation

/// Socket I/O is confined to a serial queue; the injected service is actor-isolated.
nonisolated final class AutomationSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (AutomationRequest) async -> AutomationResponse
    typealias Subscription = @Sendable () async -> AsyncStream<AutomationValue>
    private let queue = DispatchQueue(label: "com.finetune.automation.socket")
    private let handler: Handler
    private let subscription: Subscription
    private var listener: DispatchSourceRead?
    private var connections: [Int32: AutomationConnection] = [:]
    private var ownedDirectory: URL?
    private var discoveryURL: URL?
    private var instanceId: String?
    init(handler: @escaping Handler, subscription: @escaping Subscription) {
        self.handler = handler
        self.subscription = subscription
    }
    func start(discoveryURL: URL, instanceId: String) throws {
        try queue.sync {
            guard listener == nil else { return }
            try AutomationDiscovery.prepareDirectory(discoveryURL.deletingLastPathComponent())
            if let data = try? Data(contentsOf: discoveryURL),
                let existing = try? JSONDecoder().decode(AutomationDiscovery.self, from: data)
            {
                var info = stat()
                if lstat(existing.socketPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
                    info.st_uid == geteuid()
                {
                    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                    if probe >= 0 {
                        _ = fcntl(probe, F_SETFL, O_NONBLOCK)
                        var address = sockaddr_un()
                        address.sun_family = sa_family_t(AF_UNIX)
                        let bytes = Array(existing.socketPath.utf8) + [0]
                        if bytes.count <= MemoryLayout.size(ofValue: address.sun_path) {
                            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
                            let connected = withUnsafePointer(to: &address) { p in
                                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                                }
                            }
                            let code = errno
                            Darwin.close(probe)
                            if connected == 0 || code == EINPROGRESS || code == EAGAIN {
                                throw AutomationError(
                                    .conflict, "Another FineTune automation instance is running")
                            }
                        } else {
                            Darwin.close(probe)
                        }
                    }
                }
            }
            let directory = URL(
                fileURLWithPath: "/private/tmp/ft-\(geteuid())-\(UUID().uuidString.prefix(12))",
                isDirectory: true)
            guard mkdir(directory.path, 0o700) == 0 else {
                throw AutomationError(.unavailable, "Cannot create socket directory")
            }
            let path = directory.appendingPathComponent("api.sock").path
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                try? FileManager.default.removeItem(at: directory)
                throw AutomationError(.unavailable, "Cannot create socket")
            }
            var successful = false
            defer {
                if !successful {
                    Darwin.close(fd)
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw AutomationError(.unavailable, "Socket path too long")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                throw AutomationError(.unavailable, "Cannot bind private socket")
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            try AutomationDiscovery(apiVersion: 1, instanceId: instanceId, socketPath: path).publish(
                to: discoveryURL)
            self.ownedDirectory = directory
            self.discoveryURL = discoveryURL
            self.instanceId = instanceId
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            listener = source
            source.resume()
            successful = true
        }
    }
    private func acceptClients(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard connections.count < 8, getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
                Darwin.close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var enabled: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let connection = AutomationConnection(
                fd: client, queue: queue, handler: handler, subscription: subscription
            ) { [weak self] in self?.connections[client] = nil }
            connections[client] = connection
            connection.start()
        }
    }
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in Array(connections.values) { connection.close() }
            connections.removeAll()
            if let discoveryURL, let instanceId, let data = try? Data(contentsOf: discoveryURL),
                let discovery = try? JSONDecoder().decode(AutomationDiscovery.self, from: data),
                discovery.instanceId == instanceId
            {
                try? FileManager.default.removeItem(at: discoveryURL)
            }
            if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
            self.ownedDirectory = nil
            self.discoveryURL = nil
            self.instanceId = nil
        }
    }
}

nonisolated private final class AutomationConnection: @unchecked Sendable {
    let fd: Int32
    let queue: DispatchQueue
    let handler: AutomationSocketServer.Handler
    let subscription: AutomationSocketServer.Subscription
    let onClose: @Sendable () -> Void
    var decoder = AutomationFrameDecoder()
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var output = Data()
    var requests: [AutomationRequest] = []
    var processing = false
    var closed = false
    var tokens: Double = 100
    var tokenTime = ProcessInfo.processInfo.systemUptime
    var eventTask: Task<Void, Never>?
    init(
        fd: Int32, queue: DispatchQueue, handler: @escaping AutomationSocketServer.Handler,
        subscription: @escaping AutomationSocketServer.Subscription, onClose: @escaping @Sendable () -> Void
    ) {
        self.fd = fd
        self.queue = queue
        self.handler = handler
        self.subscription = subscription
        self.onClose = onClose
    }
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readFrames() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        reader = source
        source.resume()
    }
    func readFrames() {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while !closed {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                return
            }
            if count == 0 {
                close()
                return
            }
            do {
                let parsed = try decoder.append(Data(bytes.prefix(count)))
                let now = ProcessInfo.processInfo.systemUptime
                tokens = min(100, tokens + (now - tokenTime) * 100)
                tokenTime = now
                guard Double(parsed.count) <= tokens, requests.count + parsed.count <= 64 else {
                    close()
                    return
                }
                tokens -= Double(parsed.count)
                requests.append(contentsOf: parsed)
                processNext()
            } catch {
                close()
                return
            }
        }
    }
    func processNext() {
        guard !closed, !processing, !requests.isEmpty else { return }
        let request = requests.removeFirst()
        processing = true
        Task { [weak self, handler] in
            let response = await handler(request)
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.send(response)
                self.processing = false
                if request.method == "events.subscribe", response.error == nil { self.startEvents() }
                self.processNext()
            }
        }
    }
    func startEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self, subscription] in
            let stream = await subscription()
            for await event in stream {
                if Task.isCancelled { break }
                guard let self else { break }
                self.queue.async { self.send(event) }
            }
        }
    }
    func send<T: Encodable>(_ value: T) {
        guard !closed, let data = try? JSONEncoder().encode(value),
            data.count <= AutomationFrameDecoder.maximumFrame, output.count + data.count + 1 <= 4_194_304
        else {
            close()
            return
        }
        output.append(data)
        output.append(10)
        flush()
    }
    func flush() {
        while !closed && !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count > 0 {
                output.removeFirst(count)
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writer = source
                    source.resume()
                }
                return
            }
            close()
            return
        }
        writer?.cancel()
        writer = nil
    }
    func close() {
        guard !closed else { return }
        closed = true
        eventTask?.cancel()
        eventTask = nil
        writer?.cancel()
        writer = nil
        reader?.cancel()
        reader = nil
        requests.removeAll()
        output.removeAll()
        onClose()
    }
}
