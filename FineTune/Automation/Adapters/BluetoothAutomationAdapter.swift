import Foundation

@MainActor
final class BluetoothAutomationAdapter: AutomationAdapter {
    let stateKey = "bluetooth"
    let engine: AudioEngine
    init(engine: AudioEngine) { self.engine = engine }
    var descriptors: [AutomationDescriptor] {
        [
            .init(method: "bluetooth.list", title: "List Paired Audio Devices", fields: []),
            .init(
                method: "bluetooth.connect", title: "Connect Bluetooth Audio",
                fields: [.init(name: "bluetoothId", type: "string", source: "bluetooth")]),
        ]
    }
    func snapshot() -> AutomationValue {
        let m = engine.bluetoothDeviceMonitor
        return .object([
            "poweredOn": .bool(m.isBluetoothOn),
            "devices": .array(
                m.pairedDevices.map {
                    .object([
                        "id": .string($0.id), "name": .string($0.name),
                        "connecting": .bool(m.connectingIDs.contains($0.id)),
                        "error": m.connectionErrors[$0.id].map { .string($0) } ?? .null,
                    ])
                }),
        ])
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        if method == "bluetooth.list" { return snapshot() }
        let id = try AutomationParameters(params).string("bluetoothId")
        let m = engine.bluetoothDeviceMonitor
        guard m.isBluetoothOn, let device = m.pairedDevices.first(where: { $0.id == id }) else {
            throw AutomationError(.unavailable, "Paired Bluetooth audio device unavailable")
        }
        m.connect(device: device)
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(50))
            if let error = m.connectionErrors[id] { throw AutomationError(.unavailable, error) }
            if !m.connectingIDs.contains(id) {
                guard !m.pairedDevices.contains(where: { $0.id == id }) else {
                    throw AutomationError(.unavailable, "Connection did not complete")
                }
                return .object(["status": .string("applied")])
            }
        }
        throw AutomationError(.timeout, "Bluetooth connection timed out")
    }
}
