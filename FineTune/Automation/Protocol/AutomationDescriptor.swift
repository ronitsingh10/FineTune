import Foundation

nonisolated struct AutomationField: Codable, Sendable {
    let name: String
    let type: String
    var required = true
    var minimum: Double? = nil
    var maximum: Double? = nil
    var choices: [String]? = nil
    var source: String? = nil
    var ordered = false
}
nonisolated struct AutomationDescriptor: Codable, Sendable {
    let method: String
    let title: String
    let fields: [AutomationField]
    var destructive = false
    var dialParameter: String? = nil
    var units: String? = nil
    var available = true
    var unavailableReason: String? = nil
}
