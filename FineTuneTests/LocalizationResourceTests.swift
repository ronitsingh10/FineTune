// FineTuneTests/LocalizationResourceTests.swift
// Verifies that app-bundle localization resources are present and usable.

import Foundation
import Testing
@testable import FineTune

@Suite("Localization resources")
struct LocalizationResourceTests {
    // Mirrors Apple's 50 App Store localization languages for the app binary.
    // Norwegian uses the Foundation/Xcode bundle identifier `nb` rather than
    // the App Store Connect metadata shortcode `no`.
    private static let mainstreamLocaleIdentifiers: [String] = [
        "ar-SA",
        "bn-BD",
        "ca",
        "zh-Hans",
        "zh-Hant",
        "hr",
        "cs",
        "da",
        "nl-NL",
        "en-AU",
        "en-CA",
        "en-GB",
        "en-US",
        "fi",
        "fr-FR",
        "fr-CA",
        "de-DE",
        "el",
        "gu-IN",
        "he",
        "hi",
        "hu",
        "id",
        "it",
        "ja",
        "kn-IN",
        "ko",
        "ms",
        "ml-IN",
        "mr-IN",
        "nb",
        "or-IN",
        "pl",
        "pt-BR",
        "pt-PT",
        "pa-IN",
        "ro",
        "ru",
        "sk",
        "sl-SI",
        "es-MX",
        "es-ES",
        "sv",
        "ta-IN",
        "te-IN",
        "th",
        "tr",
        "uk",
        "ur-PK",
        "vi",
    ]

    private struct StringCatalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let value: String
                }

                let stringUnit: StringUnit
            }

            let localizations: [String: Localization]?
        }

        let strings: [String: Entry]
    }

    @Test("app bundle includes all mainstream localizations")
    func appBundleIncludesAllMainstreamLocalizations() {
        let localizedRegions = Set(Bundle.main.localizations)

        for localeIdentifier in Self.mainstreamLocaleIdentifiers {
            #expect(localizedRegions.contains(localeIdentifier))
        }
        #expect(!localizedRegions.contains("no"))
    }

    @Test("string catalogs include complete translations for every mainstream localization")
    func stringCatalogsIncludeCompleteTranslationsForEveryMainstreamLocalization() throws {
        let catalogURLs = [
            sourceRoot().appending(path: "FineTune/Localizable.xcstrings"),
            sourceRoot().appending(path: "FineTune/InfoPlist.xcstrings"),
        ]

        for catalogURL in catalogURLs {
            let data = try Data(contentsOf: catalogURL)
            let catalog = try JSONDecoder().decode(StringCatalog.self, from: data)
            let expectedLocaleIdentifiers = Set(Self.mainstreamLocaleIdentifiers)
            let actualLocaleIdentifiers = Set(catalog.strings.values.flatMap { entry in
                Array((entry.localizations ?? [:]).keys)
            })
            #expect(actualLocaleIdentifiers == expectedLocaleIdentifiers)

            for (key, entry) in catalog.strings {
                let localizations = entry.localizations ?? [:]
                for localeIdentifier in Self.mainstreamLocaleIdentifiers {
                    let value = localizations[localeIdentifier]?.stringUnit.value ?? ""
                    #expect(!value.isEmpty)
                    #expect(Self.formatSpecifiers(in: value) == Self.formatSpecifiers(in: key))
                }
            }
        }
    }

    @Test("InfoPlist localizations contain user-facing permission copy")
    func infoPlistLocalizationsContainUserFacingPermissionCopy() throws {
        let catalogURL = sourceRoot().appending(path: "FineTune/InfoPlist.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try JSONDecoder().decode(StringCatalog.self, from: data)
        let permissionKeys = [
            "NSAudioCaptureUsageDescription",
            "NSBluetoothAlwaysUsageDescription",
            "NSMicrophoneUsageDescription",
        ]

        for localeIdentifier in Self.mainstreamLocaleIdentifiers {
            let bundleName = catalog.strings["CFBundleName"]?.localizations?[localeIdentifier]?.stringUnit.value
            #expect(bundleName == "FineTune")

            for key in permissionKeys {
                let value = catalog.strings[key]?.localizations?[localeIdentifier]?.stringUnit.value ?? ""
                #expect(value != key)
                #expect(value.contains("FineTune"))
            }
        }
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func formatSpecifiers(in string: String) -> [String] {
        let pattern = #"%[@dfiouxX]|%l[du]|%ll[du]|%%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).map { match in
            String(string[Range(match.range, in: string)!])
        }
    }

    @Test("Simplified Chinese resources localize core UI strings")
    func simplifiedChineseResourcesLocalizeCoreUIStrings() throws {
        let appBundle = Bundle.main
        #expect(appBundle.localizations.contains("zh-Hans"))

        let zhPath = try #require(appBundle.path(forResource: "zh-Hans", ofType: "lproj"))
        let zhBundle = try #require(Bundle(path: zhPath))

        #expect(zhBundle.localizedString(forKey: "Settings", value: nil, table: nil) == "设置")
        #expect(zhBundle.localizedString(forKey: "General", value: nil, table: nil) == "通用")
        #expect(zhBundle.localizedString(forKey: "Audio", value: nil, table: nil) == "音频")
    }
}
