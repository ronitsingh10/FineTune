import Foundation

nonisolated struct AutomationRequest: Codable, Equatable, Sendable {
    let apiVersion: Int
    let id: String
    let method: String
    let params: [String: AutomationValue]
    init(apiVersion: Int = 1, id: String, method: String, params: [String: AutomationValue] = [:]) {
        self.apiVersion = apiVersion
        self.id = id
        self.method = method
        self.params = params
    }
    func validate() throws {
        guard apiVersion == 1 else {
            throw AutomationError(.unsupportedVersion, "API major version 1 required")
        }
        guard !id.isEmpty, id.utf8.count <= 128, !method.isEmpty, method.utf8.count <= 128 else {
            throw AutomationError(.invalidRequest, "Invalid request identity")
        }
    }
}

nonisolated struct AutomationResponse: Codable, Sendable {
    let apiVersion: Int
    let id: String
    let result: AutomationValue?
    let error: AutomationError?
    init(id: String, result: AutomationValue) {
        self.apiVersion = 1
        self.id = id
        self.result = result
        self.error = nil
    }
    init(id: String, error: AutomationError) {
        self.apiVersion = 1
        self.id = id
        self.result = nil
        self.error = error
    }
    enum CodingKeys: String, CodingKey { case apiVersion, id, result, error }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        id = try c.decode(String.self, forKey: .id)
        guard c.contains(.result) != c.contains(.error) else {
            throw AutomationError(.invalidRequest, "Response must have exactly one outcome")
        }
        result = c.contains(.result) ? try c.decode(AutomationValue.self, forKey: .result) : nil
        error = c.contains(.error) ? try c.decode(AutomationError.self, forKey: .error) : nil
    }
}
