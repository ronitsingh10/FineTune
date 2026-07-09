// FineTuneTests/LocalizationResourceTests.swift
// Verifies that app-bundle localization resources are present and usable.

import Foundation
import Testing
@testable import FineTune

@Suite("Localization resources")
struct LocalizationResourceTests {
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
