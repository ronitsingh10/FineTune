import Foundation

/// JSON values shared by every automation transport. Non-finite numbers are rejected.
nonisolated enum AutomationValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AutomationValue])
    case object([String: AutomationValue])
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self), v.isFinite {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([AutomationValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: AutomationValue].self))
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            guard v.isFinite else { throw AutomationError(.invalidParameter, "Number must be finite") }
            try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    var object: [String: AutomationValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var number: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
    var bool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    var array: [AutomationValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    static func encode<T: Encodable>(_ value: T) throws -> AutomationValue {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

nonisolated struct AutomationParameters {
    let values: [String: AutomationValue]
    init(_ values: [String: AutomationValue]) { self.values = values }
    func string(_ key: String) throws -> String {
        guard let v = values[key]?.string, !v.isEmpty, v.utf8.count <= 4096 else {
            throw AutomationError(.invalidParameter, "Expected nonempty string", field: key)
        }
        return v
    }
    func bool(_ key: String) throws -> Bool {
        guard let v = values[key]?.bool else {
            throw AutomationError(.invalidParameter, "Expected boolean", field: key)
        }
        return v
    }
    func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
        guard let v = values[key]?.number, v.isFinite, range.contains(v) else {
            throw AutomationError(.invalidParameter, "Expected finite number in \(range)", field: key)
        }
        return v
    }
    func integer(_ key: String, values allowed: [Int]) throws -> Int {
        guard let v = values[key]?.number, v.isFinite, let result = allowed.first(where: { Double($0) == v })
        else { throw AutomationError(.invalidParameter, "Expected one of \(allowed)", field: key) }
        return result
    }
    func strings(_ key: String, maximum: Int = 256) throws -> [String] {
        guard let array = values[key]?.array, array.count <= maximum else {
            throw AutomationError(.invalidParameter, "Expected bounded string array", field: key)
        }
        return try array.map { v in
            guard let s = v.string, !s.isEmpty, s.utf8.count <= 4096 else {
                throw AutomationError(.invalidParameter, "Invalid string array element", field: key)
            }
            return s
        }
    }
    func choice(_ key: String, _ choices: [String]) throws -> String {
        let s = try string(key)
        guard choices.contains(s) else {
            throw AutomationError(.invalidParameter, "Expected one of \(choices)", field: key)
        }
        return s
    }
}
