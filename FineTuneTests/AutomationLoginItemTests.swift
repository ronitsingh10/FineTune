import Foundation
import Testing

@testable import FineTune

@MainActor final class AutomationTestLoginItem: LoginItemManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
@Suite("Automation login item") @MainActor
struct AutomationLoginItemTests {
    @Test func temporarySettingsDoNotRequireSystemLoginItemWrites() {
        let settings = SettingsManager(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            loginItem: AutomationTestLoginItem())
        var prefs = settings.appSettings
        prefs.launchAtLogin = true
        settings.appSettings = prefs
        #expect(settings.isLaunchAtLoginEnabled)
        settings.resetAllSettings()
        #expect(!settings.isLaunchAtLoginEnabled)
        #expect(!settings.appSettings.launchAtLogin)
    }
}
