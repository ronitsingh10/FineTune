import Foundation

@MainActor
final class UpdateAutomationAdapter: AutomationAdapter {
    let stateKey = "updates"
    var manager: UpdateManager?
    #if FINETUNE_CUSTOM_BUILD
        var customBuild = true
    #else
        var customBuild = false
    #endif
    var descriptors: [AutomationDescriptor] {
        [
            .init(method: "update.status", title: "Read Update Status", fields: []),
            .init(method: "update.getPreferences", title: "Read Update Preferences", fields: []),
            .init(
                method: "update.setPreferences", title: "Set Update Preferences",
                fields: [
                    .init(name: "automaticallyChecks", type: "boolean", required: false),
                    .init(name: "automaticallyDownloads", type: "boolean", required: false),
                ], available: !customBuild,
                unavailableReason: customBuild ? "Stock updates disabled for custom distribution" : nil),
            .init(
                method: "update.check", title: "Check FineTune Updates", fields: [], available: !customBuild,
                unavailableReason: customBuild ? "Stock updates disabled for custom distribution" : nil),
        ]
    }
    func snapshot() -> AutomationValue {
        .object([
            "customBuild": .bool(customBuild),
            "canCheck": .bool(!customBuild && (manager?.canCheckForUpdates ?? false)),
            "automaticallyChecks": .bool(!customBuild && (manager?.automaticallyChecksForUpdates ?? false)),
            "automaticallyDownloads": .bool(
                !customBuild && (manager?.automaticallyDownloadsUpdates ?? false)),
        ])
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        if method == "update.status" || method == "update.getPreferences" { return snapshot() }
        guard !customBuild, let manager else {
            throw AutomationError(.unavailable, "Update service unavailable for this build")
        }
        if method == "update.check" {
            guard manager.canCheckForUpdates else { throw AutomationError(.busy, "Update check unavailable") }
            manager.checkForUpdates()
        } else {
            let p = AutomationParameters(params)
            guard params["automaticallyChecks"] != nil || params["automaticallyDownloads"] != nil else {
                throw AutomationError(.invalidParameter, "Specify an update preference")
            }
            let checks =
                params["automaticallyChecks"] == nil
                ? manager.automaticallyChecksForUpdates : try p.bool("automaticallyChecks")
            let downloads =
                params["automaticallyDownloads"] == nil
                ? manager.automaticallyDownloadsUpdates : try p.bool("automaticallyDownloads")
            manager.automaticallyChecksForUpdates = checks
            manager.automaticallyDownloadsUpdates = downloads
        }
        return .object(["status": .string("applied"), "state": snapshot()])
    }
}
