// FineTuneTests/AppSettingsKeepVolumeDuringCallsTests.swift
// Tests for the keepVolumeDuringCalls setting's default and persistence.

import Testing
import Foundation
@testable import FineTune

@Suite("AppSettings — keepVolumeDuringCalls")
struct AppSettingsKeepVolumeDuringCallsTests {

    @Test("Defaults to on for fresh settings")
    func defaultIsOn() {
        #expect(AppSettings().keepVolumeDuringCalls == true)
    }

    @Test("Settings saved by an older version decode with the setting on")
    func missingKeyDecodesAsOn() throws {
        let legacy = #"{"launchAtLogin":false,"defaultNewAppVolume":0.5}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(decoded.keepVolumeDuringCalls == true)
        #expect(decoded.defaultNewAppVolume == 0.5)
    }

    @Test("An explicit off survives a JSON round-trip")
    func offRoundTrips() throws {
        var settings = AppSettings()
        settings.keepVolumeDuringCalls = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.keepVolumeDuringCalls == false)
        #expect(decoded == settings)
    }
}
