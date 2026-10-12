import Foundation

nonisolated struct AutomationError: Error, Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case invalidRequest = "invalid_request"
        case unsupportedVersion = "unsupported_version"
        case unknownMethod = "unknown_method"
        case invalidParameter = "invalid_parameter"
        case notFound = "not_found"
        case ambiguousTarget = "ambiguous_target"
        case unavailable
        case permissionRequired = "permission_required"
        case conflict, busy, timeout
        case internalError = "internal_error"
    }
    let code: Code
    let message: String
    let field: String?
    init(_ code: Code, _ message: String, field: String? = nil) {
        self.code = code
        self.message = message
        self.field = field
    }
}
