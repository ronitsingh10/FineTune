// FineTune/WebSocket/WebSocketModels.swift
import Foundation

// MARK: - Server → Client

enum WebSocketMessage: Encodable {
    case state(StateMessage)
    case levels(LevelsMessage)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .state(let message):
            try container.encode(message)
        case .levels(let message):
            try container.encode(message)
        }
    }
}

struct StateMessage: Codable {
    let type: String = "state"
    let apps: [AppState]
    let masterVolume: Float
    let masterMuted: Bool
    let outputDevices: [DeviceState]
}

struct AppState: Codable {
    let bundleId: String
    let name: String
    let icon: String
    let volume: Float
    let isMuted: Bool
    let boost: Float
    let outputDeviceUID: String?
    let isActive: Bool
}

struct DeviceState: Codable {
    let id: String
    let name: String
}

struct LevelsMessage: Codable {
    let type: String = "levels"
    let apps: [String: AudioLevel]
}

struct AudioLevel: Codable {
    let peak: Float
}

// MARK: - Client → Server

enum WebSocketCommand: Decodable {
    case setVolume(bundleId: String, volume: Float)
    case toggleMute(bundleId: String)
    case setMasterVolume(volume: Float)
    case toggleMasterMute
    case subscribeLevels
    case unsubscribeLevels

    private enum CodingKeys: String, CodingKey {
        case type
        case bundleId
        case volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "setVolume":
            let bundleId = try container.decode(String.self, forKey: .bundleId)
            let volume = try container.decode(Float.self, forKey: .volume)
            self = .setVolume(bundleId: bundleId, volume: volume)
        case "toggleMute":
            let bundleId = try container.decode(String.self, forKey: .bundleId)
            self = .toggleMute(bundleId: bundleId)
        case "setMasterVolume":
            let volume = try container.decode(Float.self, forKey: .volume)
            self = .setMasterVolume(volume: volume)
        case "toggleMasterMute":
            self = .toggleMasterMute
        case "subscribeLevels":
            self = .subscribeLevels
        case "unsubscribeLevels":
            self = .unsubscribeLevels
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown command type: \(type)"
            )
        }
    }
}
