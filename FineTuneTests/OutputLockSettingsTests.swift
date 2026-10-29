import Foundation
import Testing
@testable import FineTune

@Suite("Output lock settings compatibility")
struct OutputLockSettingsTests {
    @Test("Existing settings keep the new lock disabled")
    func existingSettings() throws {
        let data = Data(#"{"lockInputDevice":true,"mediaKeyControlEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.lockedOutputDeviceUID == nil)
        #expect(settings.lockInputDevice)
        #expect(settings.mediaKeyControlEnabled)
    }

    @Test("Chosen device survives serialization without changing mute-independent preferences")
    func chosenDeviceRoundTrip() throws {
        var settings = AppSettings()
        settings.lockedOutputDeviceUID = "test-display-uid"
        settings.defaultNewAppVolume = 0.2
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }
}
