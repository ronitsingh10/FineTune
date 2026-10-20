import Foundation
import Observation
import os

@Observable
@MainActor
final class ControlService {
    private(set) var startupFailure: String?
    private(set) var sessionID = ""
    private(set) var revision: UInt64 = 0
    private let engine: any ControlEngine
    private let settings: SettingsManager?
    private let server: UnixSocketServer
    private let send: @MainActor (Data, UUID, @escaping @MainActor () -> Void) -> Void
    private let onReady: @MainActor () -> Void
    private let disconnect: @MainActor (UUID) -> Void
    private let schedule: @MainActor (@escaping @MainActor () -> Void) -> Task<Void, Never>
    private var clients: [UUID: Set<String>] = [:]
    private var subscribers: Set<UUID> = []
    private var published: ControlJSON = .null
    private var publication: Task<Void, Never>?
    private var running = false
    private var observingSettings = false
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "ControlAPI")

    init(
        engine: any ControlEngine,
        settings: SettingsManager? = nil,
        server: UnixSocketServer = UnixSocketServer(),
        send: (@MainActor (Data, UUID, @escaping @MainActor () -> Void) -> Void)? = nil,
        disconnect: (@MainActor (UUID) -> Void)? = nil,
        onReady: @escaping @MainActor () -> Void = {},
        schedule: @escaping @MainActor (@escaping @MainActor () -> Void) -> Task<Void, Never> = { action in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                action()
            }
        }
    ) {
        self.engine = engine
        self.settings = settings
        self.server = server
        self.send = send ?? { data, id, completed in
            server.send(data, to: id) { DispatchQueue.main.async { completed() } }
        }
        self.onReady = onReady
        self.disconnect = disconnect ?? { server.disconnect($0) }
        self.schedule = schedule
    }

    /// Lives at app scope, not in the menu bar popup's view lifecycle.
    func observeSetting() {
        guard !observingSettings else { return }
        observingSettings = true
        trackSetting()
    }

    private func trackSetting() {
        guard observingSettings, let settings else { return }
        let enabled = withObservationTracking {
            settings.appSettings.externalControlEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackSetting() }
        }
        if enabled { start() } else { stopListener() }
    }

    func start(listen: Bool = true) {
        guard !running else { return }
        running = true
        startupFailure = nil
        sessionID = UUID().uuidString
        revision = 0
        published = engine.controlState()
        trackState(session: sessionID)
        guard listen else { return }
        let session = sessionID
        server.start(onConnect: { [weak self] id in
            DispatchQueue.main.async { self?.connected(id, session: session) }
        }, onFrame: { [weak self] id, data, completed in
            DispatchQueue.main.async {
                self?.received(data, from: id, session: session)
                completed()
            }
        }, onDisconnect: { [weak self] id in
            DispatchQueue.main.async {
                guard self?.sessionID == session else { return }
                self?.clients.removeValue(forKey: id)
                self?.subscribers.remove(id)
            }
        }, onFailure: { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.sessionID == session else { return }
                self.stopListener()
                self.startupFailure = message
            }
        }, onReady: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.running, self.sessionID == session else { return }
                self.onReady()
            }
        })
    }

    func stop(completion: @escaping @Sendable () -> Void = {}) {
        observingSettings = false
        stopListener(completion: completion)
    }

    private func stopListener(completion: @escaping @Sendable () -> Void = {}) {
        running = false
        publication?.cancel()
        publication = nil
        clients.removeAll()
        subscribers.removeAll()
        server.stop(completion: completion)
    }

    private func trackState(session: String) {
        guard running, sessionID == session else { return }
        _ = withObservationTracking {
            engine.controlState()
        } onChange: { [weak self] in
            // onChange runs before mutation. Re-arm next turn independently of publication.
            DispatchQueue.main.async {
                guard let self, self.running, self.sessionID == session else { return }
                self.trackState(session: session)
                if self.publication == nil {
                    self.publication = self.schedule { [weak self] in
                        guard let self, self.sessionID == session else { return }
                        self.publication = nil
                        self.flush()
                    }
                }
            }
        }
    }

    func connected(_ id: UUID, session: String) {
        guard running, sessionID == session else { disconnect(id); return }
        clients[id] = []
        enqueue(.object([
            "type": .string("hello"), "protocol": .string("finetune-control"), "version": .number(1),
            "appVersion": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            "sessionId": .string(sessionID), "capabilities": .array(ControlCommand.capabilities.map(ControlJSON.string))
        ]), to: id)
    }

    func received(_ data: Data, from id: UUID, session: String) {
        guard running, sessionID == session, clients[id] != nil else { return }
        let request: ControlRequest
        do {
            request = try ControlRequest(data: data)
            guard clients[id]?.contains(request.id) == false else { close(id); return }
            clients[id]?.insert(request.id)
        } catch { close(id); return }
        do {
            guard request.sessionID == sessionID else {
                throw ControlFailure(code: "staleSession", message: "Read the current hello before issuing commands")
            }
            let command = try ControlCommand.parse(method: request.method, params: request.params)
            switch command {
            case .getState, .subscribe:
                if command == .subscribe { subscribers.remove(id) }
                flush()
                respond(request.id, result: snapshot(), to: id)
                if command == .subscribe { subscribers.insert(id) }
            default:
                try engine.performControlCommand(command)
                // No suspension between dispatch and enqueue: command-caused events follow this response.
                respond(request.id, result: .object(["accepted": .bool(true)]), to: id)
            }
        } catch let failure as ControlFailure {
            enqueue(.object(["type": .string("response"), "id": .string(request.id), "error": failure.json]), to: id, requestID: request.id)
        } catch {
            logger.error("External controller command failed: \(error.localizedDescription)")
            let failure = ControlFailure(code: "internalError", message: "Unable to execute command")
            enqueue(.object(["type": .string("response"), "id": .string(request.id), "error": failure.json]), to: id, requestID: request.id)
        }
    }

    func flush() {
        guard running else { return }
        publication?.cancel()
        publication = nil
        let state = engine.controlState()
        guard state != published else { return }
        guard revision < 9_007_199_254_740_991 else {
            logger.error("External controller revision exhausted; closing listener")
            stopListener()
            return
        }
        published = state
        revision += 1
        let event = ControlJSON.object([
            "type": .string("event"), "event": .string("stateChanged"),
            "sessionId": .string(sessionID), "revision": .number(Double(revision)), "state": published
        ])
        for id in subscribers { enqueue(event, to: id) }
    }

    private func snapshot() -> ControlJSON {
        .object(["sessionId": .string(sessionID), "revision": .number(Double(revision)), "state": published])
    }

    private func respond(_ requestID: String, result: ControlJSON, to id: UUID) {
        enqueue(.object(["type": .string("response"), "id": .string(requestID), "result": result]), to: id, requestID: requestID)
    }

    var pendingRequestCount: Int { clients.values.reduce(0) { $0 + $1.count } }

    private func enqueue(_ value: ControlJSON, to id: UUID, requestID: String? = nil) {
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= UnixSocketServer.maximumFrameBytes else {
                logger.error("External controller snapshot exceeds frame limit")
                close(id)
                return
            }
            let session = sessionID
            send(data, id) { [weak self] in
                guard let self, self.sessionID == session, let requestID else { return }
                self.clients[id]?.remove(requestID)
            }
        } catch {
            logger.error("Cannot encode external controller snapshot: \(error.localizedDescription)")
            close(id)
        }
    }

    private func close(_ id: UUID) {
        clients.removeValue(forKey: id)
        subscribers.remove(id)
        disconnect(id)
    }
}
