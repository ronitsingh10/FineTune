import ServiceManagement

@MainActor
protocol LoginItemManaging: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}
@MainActor
final class SystemLoginItemManager: LoginItemManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
