import Foundation

nonisolated enum AutomationTarget: Equatable, Sendable {
    case app(String, instanceID: Int32?)
    case device(String, direction: String)
    case selector(String)
    static func parse(_ value: AutomationValue?) throws -> Self {
        guard let o = value?.object else {
            throw AutomationError(.invalidParameter, "Expected target", field: "target")
        }
        let identities = ["appId", "deviceUID", "selector"].filter { o[$0] != nil }
        guard identities.count == 1 else {
            throw AutomationError(.invalidParameter, "Target needs exactly one identity", field: "target")
        }
        let p = AutomationParameters(o)
        if o["appId"] != nil {
            var pid: Int32?
            if let v = o["instanceId"] {
                guard let n = v.number, n.isFinite, n.rounded() == n, n > 0, n <= Double(Int32.max) else {
                    throw AutomationError(.invalidParameter, "Invalid runtime ID", field: "instanceId")
                }
                pid = Int32(n)
            }
            return .app(try p.string("appId"), instanceID: pid)
        }
        if o["deviceUID"] != nil {
            return .device(
                try p.string("deviceUID"),
                direction: o["direction"] == nil ? "output" : try p.choice("direction", ["input", "output"]))
        }
        return .selector(try p.choice("selector", ["defaultOutput", "defaultInput", "audibleApp"]))
    }
}
