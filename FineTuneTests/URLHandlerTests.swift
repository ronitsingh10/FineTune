import AppKit
import Testing
@testable import FineTune

@Suite("URL volume percentages")
@MainActor
struct URLHandlerTests {
    @Test("URL volume matches the displayed percentage for active and inactive apps",
          arguments: [0, 10, 20, 30, 50, 100])
    func displayedPercentage(percent: Int) throws {
        let engine = RecordingURLEngine()
        let handler = URLHandler(audioEngine: engine)
        handler.handleURL(try #require(URL(string:
            "finetune://set-volumes?app=com.test.active&volume=\(percent)&app=com.test.inactive&volume=\(percent)"
        )))

        #expect(engine.volumes.count == 2)
        for identifier in ["com.test.active", "com.test.inactive"] {
            let gain = try #require(engine.volumes[identifier])
            #expect(abs(VolumeMapping.gainToSlider(gain) * 100 - Double(percent)) < 0.0001)
        }
    }

    @Test("Invalid percentages are skipped without losing subsequent valid pairs")
    func invalidPercentages() throws {
        let engine = RecordingURLEngine()
        URLHandler(audioEngine: engine).handleURL(try #require(URL(string:
            "finetune://set-volumes?app=negative&volume=-1&app=over&volume=101&app=text&volume=bad&app=com.test.active&volume=50"
        )))
        #expect(engine.volumes.count == 1)
        #expect(engine.volumes["com.test.active"] == 0.25)
    }
}

@MainActor
private final class RecordingURLEngine: URLHandlerEngine {
    let settingsManager = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let apps = [AudioApp(id: 42424, processObjectIDs: [], name: "Test App", icon: NSImage(), bundleID: "com.test.active")]
    var volumes: [String: Float] = [:]

    func setVolume(for app: AudioApp, to volume: Float) { volumes[app.persistenceIdentifier] = volume }
    func getVolume(for app: AudioApp) -> Float { volumes[app.persistenceIdentifier] ?? 1 }
    func setVolumeForInactive(identifier: String, to volume: Float) { volumes[identifier] = volume }
    func setMute(for app: AudioApp, to muted: Bool) { Issue.record("Unexpected mute write") }
    func getMute(for app: AudioApp) -> Bool { false }
    func setDevice(for app: AudioApp, deviceUID: String?) { Issue.record("Unexpected routing write") }
    func setMuteForInactive(identifier: String, to muted: Bool) { Issue.record("Unexpected mute write") }
    func getMuteForInactive(identifier: String) -> Bool { false }
}
