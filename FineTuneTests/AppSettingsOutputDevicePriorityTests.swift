import Foundation
import Testing
@testable import FineTune

@Suite("Output device priority preference")
@MainActor
struct AppSettingsOutputDevicePriorityTests {
    @Test("New settings follow macOS output switching")
    func defaultsToFollowingMacOS() {
        #expect(AppSettings().outputDevicePriorityEnabled == false)
    }

    @Test("Legacy settings keep saved routes and order without enabling output overrides")
    func legacySettingsFollowMacOS() throws {
        let json = """
        {
            "outputDevicePriority": ["speakers", "airpods"],
            "appDeviceRouting": {"com.test.player": "speakers"},
            "appSettings": {"lockInputDevice": true}
        }
        """
        let settings = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))

        #expect(settings.appSettings.outputDevicePriorityEnabled == false)
        #expect(settings.appSettings.lockInputDevice == true)
        #expect(settings.outputDevicePriority == ["speakers", "airpods"])
        #expect(settings.appDeviceRouting["com.test.player"] == "speakers")
    }

    @Test("Output priority preference persists across relaunch", arguments: [true, false])
    func persistsAcrossRelaunch(enabled: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        // Start with the opposite value so both enabling and disabling exercise a change.
        manager.appSettings.outputDevicePriorityEnabled = !enabled
        manager.flushSync()
        manager.appSettings.outputDevicePriorityEnabled = enabled
        manager.flushSync()

        let restored = SettingsManager(directory: directory)
        #expect(restored.appSettings.outputDevicePriorityEnabled == enabled)
    }
}
