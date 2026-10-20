import Foundation

nonisolated enum ControlJSON: Codable, Equatable, Sendable {
    case object([String: ControlJSON]), array([ControlJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: ControlJSON].self) { self = .object(value) }
        else { self = .array(try c.decode([ControlJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: ControlJSON]? { if case .object(let value) = self { value } else { nil } }
    static func optional(_ value: String?) -> Self { value.map(Self.string) ?? .null }
    static func optional(_ value: Float?) -> Self { value.map { .number(Double($0)) } ?? .null }
    static func optional(_ value: Bool?) -> Self { value.map(Self.bool) ?? .null }
}

nonisolated struct ControlFailure: LocalizedError, Equatable, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    var json: ControlJSON { .object(["code": .string(code), "message": .string(message)]) }
}

nonisolated enum ControlCommand: Equatable, Sendable {
    case getState, subscribe
    case volume(String, Int32?, Float)
    case mute(String, Int32?, Bool)
    case routing(String, Int32?, String?)
    case defaultOutput(String)
    case preferredInput(String)

    static let capabilities = ["getState", "subscribe", "setAppVolume", "setAppMute", "setAppRouting", "setDefaultOutput", "setPreferredInput"]

    static func parse(method: String, params: [String: ControlJSON]) throws -> Self {
        func string(_ key: String, in values: [String: ControlJSON]) throws -> String {
            guard let value = values[key]?.string, !value.isEmpty else {
                throw ControlFailure(code: "invalidParams", message: "\(key) must be a nonempty string")
            }
            return value
        }
        switch method {
        case "getState": return .getState
        case "subscribe": return .subscribe
        case "setDefaultOutput": return .defaultOutput(try string("deviceUID", in: params))
        case "setPreferredInput": return .preferredInput(try string("deviceUID", in: params))
        case "setAppVolume", "setAppMute", "setAppRouting":
            let appID = try string("appId", in: params)
            var pid: Int32?
            if let value = params["pid"] {
                guard case .number(let number) = value, number > 0,
                      number <= Double(Int32.max), number.rounded() == number else {
                    throw ControlFailure(code: "invalidParams", message: "pid must be a positive integer")
                }
                pid = Int32(number)
            }
            if method == "setAppVolume" {
                guard case .number(let volume) = params["volume"], volume.isFinite, (0...1).contains(volume) else {
                    throw ControlFailure(code: "invalidParams", message: "volume must be finite and between 0 and 1")
                }
                return .volume(appID, pid, Float(volume))
            }
            if method == "setAppMute" {
                guard case .bool(let muted) = params["muted"] else {
                    throw ControlFailure(code: "invalidParams", message: "muted must be a boolean")
                }
                return .mute(appID, pid, muted)
            }
            guard let routing = params["routing"]?.object else {
                throw ControlFailure(code: "invalidParams", message: "routing must be an object")
            }
            switch try string("mode", in: routing) {
            case "followDefault": return .routing(appID, pid, nil)
            case "single": return .routing(appID, pid, try string("deviceUID", in: routing))
            case "multi": throw ControlFailure(code: "unsupportedRouting", message: "Multi-output routing is read-only")
            default: throw ControlFailure(code: "invalidParams", message: "Unknown routing mode")
            }
        default: throw ControlFailure(code: "unknownMethod", message: "Unknown method: \(method)")
        }
    }
}

nonisolated struct ControlRequest {
    let id: String
    let sessionID: String
    let method: String
    let params: [String: ControlJSON]

    init(data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil,
              let object = try JSONDecoder().decode(ControlJSON.self, from: data).object,
              object["type"] == .string("request"),
              let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 128,
              let sessionID = object["sessionId"]?.string,
              let method = object["method"]?.string,
              let params = object["params"]?.object else {
            throw ControlFailure(code: "invalidEnvelope", message: "Malformed request envelope")
        }
        self.id = id
        self.sessionID = sessionID
        self.method = method
        self.params = params
    }
}

@MainActor
protocol ControlEngine: AnyObject {
    /// Must read observable dependencies, including asynchronous routing completion state.
    func controlState() -> ControlJSON
    func performControlCommand(_ command: ControlCommand) throws
}
