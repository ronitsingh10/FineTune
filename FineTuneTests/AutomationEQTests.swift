import Foundation
import Testing

@testable import FineTune

@Suite("EQ automation") @MainActor
struct AutomationEQTests {
    @Test func activeAppWithoutTapStoresEQIntent() async {
        let e = makeAutomationEngine(apps: [automationApp(123460)])
        let r = await AutomationService(engine: e).execute(
            .init(
                id: "eq", method: "app.eq.band.set",
                params: [
                    "target": .object(["appId": .string("com.test.player")]), "band": .number(0),
                    "gainDB": .number(6),
                ]))
        #expect(e.settingsManager.getEQSettings(for: "com.test.player").bandGains[0] == 6)
        #expect(r.result?.object?["status"] == .string("stored"))
    }
    @Test func patchPreservesOtherBands() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let t: AutomationValue = .object(["appId": .string("com.test.player")])
        _ = await s.execute(
            .init(
                id: "1", method: "app.eq.band.set",
                params: ["target": t, "band": .number(0), "gainDB": .number(6)]))
        _ = await s.execute(
            .init(
                id: "2", method: "app.eq.band.set",
                params: ["target": t, "band": .number(9), "gainDB": .number(-3)]))
        let eq = e.settingsManager.getEQSettings(for: "com.test.player")
        #expect(eq.bandGains == [6, 0, 0, 0, 0, 0, 0, 0, 0, -3])
        let bad = await s.execute(
            .init(
                id: "3", method: "app.eq.band.set",
                params: ["target": t, "band": .number(0), "gainDB": .number(13)]))
        #expect(bad.error?.code == .invalidParameter)
        #expect(e.settingsManager.getEQSettings(for: "com.test.player").bandGains[0] == 6)
    }
    @Test func userPresetIdentityAndNames() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let r = await s.execute(
            .init(
                id: "1", method: "eq.preset.create",
                params: [
                    "name": .string("Voice"), "bandGains": .array(Array(repeating: .number(1), count: 10)),
                ]))
        #expect(r.error == nil)
        _ = await s.execute(
            .init(
                id: "2", method: "eq.preset.create",
                params: [
                    "name": .string("Voice"), "bandGains": .array(Array(repeating: .number(0), count: 10)),
                ]))
        #expect(Set(e.settingsManager.getUserPresets().map(\.name)) == ["Voice", "Voice (2)"])
    }
}
@Suite("Preferences automation") @MainActor
struct AutomationPreferencesTests {
    @Test func patchesWithoutSettingsViewAndRejectsUnknownKey() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let r = await s.execute(
            .init(
                id: "1", method: "preferences.patch",
                params: [
                    "settings": .object(["appearance": .string("dark"), "defaultNewAppVolume": .number(0.3)])
                ]))
        #expect(r.error == nil)
        #expect(e.settingsManager.appSettings.appearance == .dark)
        #expect(e.settingsManager.appSettings.defaultNewAppVolume == 0.3)
        let bad = await s.execute(
            .init(
                id: "2", method: "preferences.patch",
                params: ["settings": .object(["appearance": .string("light"), "unknown": .bool(true)])]))
        #expect(bad.error?.code == .invalidParameter)
        #expect(e.settingsManager.appSettings.appearance == .dark)
    }
    @Test func unifiedLoudnessUpdatesBothOptions() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let r = await s.execute(.init(id: "1", method: "loudness.set", params: ["enabled": .bool(true)]))
        #expect(r.error == nil)
        #expect(e.settingsManager.appSettings.loudnessCompensationEnabled)
        #expect(e.settingsManager.appSettings.loudnessEqualizationEnabled)
    }
    @Test func pinAndIgnoreDiscoverInactiveIdentity() async {
        let e = makeAutomationEngine()
        let s = AutomationService(engine: e)
        let t: AutomationValue = .object(["appId": .string("com.test.player")])
        let r = await s.execute(
            .init(id: "1", method: "app.pin.set", params: ["target": t, "pinned": .bool(true)]))
        #expect(r.error == nil)
        #expect(e.isPinned(identifier: "com.test.player"))
        _ = await s.execute(
            .init(id: "2", method: "app.ignore.set", params: ["target": t, "ignored": .bool(true)]))
        #expect(e.isIgnored(identifier: "com.test.player"))
        #expect(!e.isPinned(identifier: "com.test.player"))
    }
}
