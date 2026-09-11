import Foundation
import Testing
@testable import FineTune

@Suite("Localization catalogs")
struct LocalizationTests {
    private let english = Locale(identifier: "en")
    private let simplifiedChinese = Locale(identifier: "zh-Hans")

    @Test("Representative strings resolve in English and Simplified Chinese")
    func representativeRuntimeStrings() {
        #expect(String(localized: LocalizedStringResource("Settings", locale: english)) == "Settings")
        #expect(String(localized: LocalizedStringResource("Settings", locale: simplifiedChinese)) == "设置")
        #expect(String(localized: LocalizedStringResource("Output Devices", locale: simplifiedChinese)) == "输出设备")
        #expect(String(localized: LocalizedStringResource("AutoEQ correction", locale: simplifiedChinese)) == "AutoEQ 耳机校正")
    }

    @Test("English quantity strings use singular and plural forms")
    func englishPluralForms() {
        #expect(String(localized: LocalizedStringResource("\(1) devices", locale: english)) == "1 device")
        #expect(String(localized: LocalizedStringResource("\(2) devices", locale: english)) == "2 devices")
    }

    @Test("Every translatable app string has a Simplified Chinese value with matching placeholders")
    func appCatalogCoverageAndPlaceholders() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try #require(catalog["strings"] as? [String: Any])

        for (source, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any])
            if entry["shouldTranslate"] as? Bool == false { continue }

            let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(source)")
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any], "Missing zh-Hans for \(source)")
            let unit = try #require(chinese["stringUnit"] as? [String: Any], "Missing zh-Hans string unit for \(source)")
            let value = try #require(unit["value"] as? String)

            #expect(placeholders(in: value) == placeholders(in: source), "Placeholder mismatch for \(source): \(value)")
        }
    }

    @Test("Info.plist permissions include English and Simplified Chinese")
    func infoPlistPermissions() throws {
        let catalog = try catalog(named: "InfoPlist")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedKeys = [
            "NSAudioCaptureUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSBluetoothAlwaysUsageDescription"
        ]

        for key in expectedKeys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let englishValue = try localizedValue(in: localizations, language: "en")
            let chineseValue = try localizedValue(in: localizations, language: "zh-Hans")
            #expect(!englishValue.isEmpty)
            #expect(!chineseValue.isEmpty)
        }
    }

    @Test("Localized display values do not change persisted raw values")
    func rawValuesRemainStable() throws {
        #expect(MenuBarIconStyle.default.rawValue == "Default")
        #expect(AppearancePreference.system.rawValue == "system")
        #expect(MenuBarPopupSize.comfortable.rawValue == "comfortable")
        #expect(VolumeHotkeyStep.extraFine.rawValue == "extraFine")
        #expect(EQPreset.bassBoost.rawValue == "bassBoost")

        let data = try JSONEncoder().encode(MenuBarPopupSize.spacious)
        #expect(try JSONDecoder().decode(MenuBarPopupSize.self, from: data) == .spacious)
    }

    private func catalog(named name: String) throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = projectRoot
            .appendingPathComponent("FineTune", isDirectory: true)
            .appendingPathComponent("\(name).xcstrings")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func localizedValue(in localizations: [String: Any], language: String) throws -> String {
        let localization = try #require(localizations[language] as? [String: Any])
        let unit = try #require(localization["stringUnit"] as? [String: Any])
        return try #require(unit["value"] as? String)
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(@|lld|ld|d|f|s)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[capture])
        }.sorted()
    }
}
