// FineTune/WebSocket/WebSocketServer.swift
import Foundation
import Network
import os

@MainActor
final class WebSocketServer {

    // MARK: - Properties

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "WebSocketServer")

    private var listener: NWListener?
    private var clients: [NWConnection] = []
    private var levelsSubscribers: Set<ObjectIdentifier> = []

    private let port: NWEndpoint.Port = NWEndpoint.Port(rawValue: 17320)!
    private let encoder = JSONEncoder()

    var onCommand: ((WebSocketCommand) -> Void)?
    var onLevelsSubscriptionChanged: ((Bool) -> Void)?

    var hasLevelsSubscribers: Bool {
        !levelsSubscribers.isEmpty
    }

    // MARK: - Lifecycle

    func start() {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            logger.error("Failed to create WebSocket listener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }

        // Bind to localhost only
        listener?.parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: port
        )

        listener?.start(queue: .main)
        logger.info("WebSocket server starting on 127.0.0.1:\(self.port.rawValue)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients {
            client.cancel()
        }
        clients.removeAll()
        let hadSubscribers = !levelsSubscribers.isEmpty
        levelsSubscribers.removeAll()
        if hadSubscribers {
            onLevelsSubscriptionChanged?(false)
        }
        logger.info("WebSocket server stopped")
    }

    // MARK: - Broadcasting

    func broadcast(_ message: WebSocketMessage) {
        guard !clients.isEmpty else { return }

        guard let data = try? encoder.encode(message) else {
            logger.error("Failed to encode WebSocket message")
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "websocket",
            metadata: [metadata]
        )

        for client in clients {
            client.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        self.logger.warning("Send failed: \(error.localizedDescription)")
                    }
                }
            )
        }
    }

    func broadcastLevels(_ message: WebSocketMessage) {
        guard !levelsSubscribers.isEmpty else { return }

        guard let data = try? encoder.encode(message) else {
            logger.error("Failed to encode levels message")
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "websocket",
            metadata: [metadata]
        )

        for client in clients where levelsSubscribers.contains(ObjectIdentifier(client)) {
            client.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        self.logger.warning("Levels send failed: \(error.localizedDescription)")
                    }
                }
            )
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        logger.info("New WebSocket client connecting")
        clients.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor in
                self?.handleConnectionState(connection, state: state)
            }
        }

        connection.start(queue: .main)
        receiveMessage(from: connection)
    }

    private func handleConnectionState(_ connection: NWConnection, state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("WebSocket client connected")
        case .failed(let error):
            logger.warning("WebSocket client failed: \(error.localizedDescription)")
            removeClient(connection)
        case .cancelled:
            logger.info("WebSocket client disconnected")
            removeClient(connection)
        default:
            break
        }
    }

    private func removeClient(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        clients.removeAll { $0 === connection }

        let wasSubscribed = levelsSubscribers.remove(id) != nil
        if wasSubscribed && levelsSubscribers.isEmpty {
            onLevelsSubscriptionChanged?(false)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("WebSocket server listening on 127.0.0.1:\(self.port.rawValue)")
        case .failed(let error):
            logger.error("WebSocket listener failed: \(error.localizedDescription)")
            // Attempt restart after a delay
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.stop()
                self.start()
            }
        case .cancelled:
            logger.info("WebSocket listener cancelled")
        default:
            break
        }
    }

    // MARK: - Message Receiving

    private func receiveMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, contentContext, _, error in
            guard let self, let connection else { return }

            Task { @MainActor in
                if let error {
                    self.logger.warning("Receive error: \(error.localizedDescription)")
                    return
                }

                if let data = content,
                   let metadata = contentContext?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .text {
                    self.handleTextMessage(data, from: connection)
                }

                // Continue receiving
                self.receiveMessage(from: connection)
            }
        }
    }

    private func handleTextMessage(_ data: Data, from connection: NWConnection) {
        do {
            let command = try JSONDecoder().decode(WebSocketCommand.self, from: data)

            switch command {
            case .subscribeLevels:
                let wasEmpty = levelsSubscribers.isEmpty
                levelsSubscribers.insert(ObjectIdentifier(connection))
                if wasEmpty {
                    onLevelsSubscriptionChanged?(true)
                }
            case .unsubscribeLevels:
                levelsSubscribers.remove(ObjectIdentifier(connection))
                if levelsSubscribers.isEmpty {
                    onLevelsSubscriptionChanged?(false)
                }
            default:
                onCommand?(command)
            }
        } catch {
            logger.warning("Failed to decode command: \(error.localizedDescription)")
        }
    }
}
