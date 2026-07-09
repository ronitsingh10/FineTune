// FineTuneTests/AppLanguagePreferenceTests.swift
// Tests for the in-app language selector preference.

import Foundation
import Testing
@testable import FineTune

@Suite("AppLanguagePreference")
struct AppLanguagePreferenceTests {
    @Test("default follows system language")
    func defaultFollowsSystemLanguage() {
        let settings = AppSettings()
        #expect(settings.languagePreference == .system)
    }

    @Test("all language options round-trip through JSON")
    func allCasesRoundTrip() throws {
        for preference in AppLanguagePreference.allCases {
            let data = try JSONEncoder().encode(preference)
            let decoded = try JSONDecoder().decode(AppLanguagePreference.self, from: data)
            #expect(decoded == preference)
        }
    }

    @Test("Simplified Chinese app setting round-trips through JSON")
    func simplifiedChineseSettingRoundTrip() throws {
        var settings = AppSettings()
        settings.languagePreference = .simplifiedChinese

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.languagePreference == .simplifiedChinese)
    }

    @Test("missing languagePreference key decodes to system")
    func missingLanguagePreferenceDefaultsToSystem() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.languagePreference == .system)
    }

    @Test("preference applies the correct AppleLanguages override")
    func appliesAppleLanguagesOverride() throws {
        let suiteName = "FineTune.AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppLanguagePreference.simplifiedChinese.apply(to: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])

        AppLanguagePreference.english.apply(to: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        AppLanguagePreference.system.apply(to: defaults)
        let persistedDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        #expect(persistedDomain["AppleLanguages"] == nil)
    }
}
