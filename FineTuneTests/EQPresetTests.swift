// FineTuneTests/EQPresetTests.swift
// Tests for EQPreset definitions, EQSettings normalization, and band contracts.
// Pure logic — no audio hardware, no CoreAudio.

import Testing
import Foundation
@testable import FineTune

// MARK: - EQPreset — Catalog Completeness

@Suite("EQPreset — Catalog")
struct EQPresetCatalogTests {

    @Test("allCases count is 20")
    func allCasesCount() {
        #expect(EQPreset.allCases.count == 20)
    }

    @Test("Every preset has a non-empty name")
    func allPresetsHaveNames() {
        for preset in EQPreset.allCases {
            #expect(!preset.name.isEmpty, "Preset \(preset.rawValue) has empty name")
        }
    }

    @Test("Every preset has a category")
    func allPresetsHaveCategories() {
        for preset in EQPreset.allCases {
            // Accessing category should not crash; coverage check
            _ = preset.category
        }
    }

    @Test("All categories have at least one preset")
    func allCategoriesCovered() {
        for category in EQPreset.Category.allCases {
            let presets = EQPreset.presets(for: category)
            #expect(!presets.isEmpty, "Category \(category.rawValue) has no presets")
        }
    }

    @Test("presets(for:) returns only presets matching that category")
    func presetsForCategoryAreCorrect() {
        for category in EQPreset.Category.allCases {
            let presets = EQPreset.presets(for: category)
            for preset in presets {
                #expect(preset.category == category,
                        "Preset \(preset.rawValue) has category \(preset.category) but was returned by presets(for: \(category))")
            }
        }
    }

    @Test("Sum of presets across all categories equals allCases")
    func categoryPartitionIsComplete() {
        let totalFromCategories = EQPreset.Category.allCases.reduce(0) { sum, cat in
            sum + EQPreset.presets(for: cat).count
        }
        #expect(totalFromCategories == EQPreset.allCases.count)
    }
}

// MARK: - EQPreset — Band Gains

@Suite("EQPreset — Band gain contracts")
struct EQPresetBandGainTests {

    @Test("Every preset produces exactly 10 band gains")
    func allPresetsHave10Bands() {
        for preset in EQPreset.allCases {
            #expect(preset.settings.bandGains.count == EQSettings.bandCount,
                    "Preset \(preset.rawValue) has \(preset.settings.bandGains.count) bands, expected \(EQSettings.bandCount)")
        }
    }

    @Test("All preset band gains are within ±12 dB range")
    func allGainsWithinRange() {
        for preset in EQPreset.allCases {
            for (index, gain) in preset.settings.bandGains.enumerated() {
                #expect(gain >= EQSettings.minGainDB && gain <= EQSettings.maxGainDB,
                        "Preset \(preset.rawValue) band \(index) gain \(gain) out of range [\(EQSettings.minGainDB), \(EQSettings.maxGainDB)]")
            }
        }
    }

    @Test("Flat preset has all-zero gains")
    func flatPresetAllZeros() {
        let gains = EQPreset.flat.settings.bandGains
        for (index, gain) in gains.enumerated() {
            #expect(gain == 0, "Flat preset band \(index) has gain \(gain), expected 0")
        }
    }

    @Test("All preset gains are finite (no NaN or infinity)")
    func allGainsFinite() {
        for preset in EQPreset.allCases {
            for (index, gain) in preset.settings.bandGains.enumerated() {
                #expect(gain.isFinite, "Preset \(preset.rawValue) band \(index) has non-finite gain \(gain)")
            }
        }
    }
}

// MARK: - EQSettings — Normalization

@Suite("EQSettings — Normalization and clamping")
struct EQSettingsNormalizationTests {

    @Test("Init with fewer than 10 bands pads with zeros")
    func padShortBands() {
        let eq = EQSettings(bandGains: [1.0, 2.0, 3.0])
        #expect(eq.bandGains.count == EQSettings.bandCount)
        #expect(eq.bandGains[0] == 1.0)
        #expect(eq.bandGains[1] == 2.0)
        #expect(eq.bandGains[2] == 3.0)
        for i in 3..<EQSettings.bandCount {
            #expect(eq.bandGains[i] == 0, "Band \(i) should be 0 after padding, got \(eq.bandGains[i])")
        }
    }

    @Test("Init with more than 10 bands truncates")
    func truncateLongBands() {
        let gains = (0..<15).map { Float($0) }
        let eq = EQSettings(bandGains: gains)
        #expect(eq.bandGains.count == EQSettings.bandCount)
        #expect(eq.bandGains[9] == 9.0)
    }

    @Test("Init with exactly 10 bands preserves all")
    func exactBandCount() {
        let gains: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let eq = EQSettings(bandGains: gains)
        #expect(eq.bandGains == gains)
    }

    @Test("Init with empty array pads to 10 zeros")
    func emptyArrayPads() {
        let eq = EQSettings(bandGains: [])
        #expect(eq.bandGains.count == EQSettings.bandCount)
        #expect(eq.bandGains.allSatisfy { $0 == 0 })
    }

    @Test("clampedGains clamps values outside ±12 dB")
    func clampedGains() {
        let eq = EQSettings(bandGains: [-20, -12, 0, 12, 20, 0, 0, 0, 0, 0])
        let clamped = eq.clampedGains
        #expect(clamped[0] == EQSettings.minGainDB) // -20 → -12
        #expect(clamped[1] == EQSettings.minGainDB) // -12 stays
        #expect(clamped[2] == 0)                     // 0 stays
        #expect(clamped[3] == EQSettings.maxGainDB)  // 12 stays
        #expect(clamped[4] == EQSettings.maxGainDB)  // 20 → 12
    }

    @Test("clampedGains handles NaN by replacing with 0")
    func clampedGainsNaN() {
        let eq = EQSettings(bandGains: [.nan, 5.0, 0, 0, 0, 0, 0, 0, 0, 0])
        let clamped = eq.clampedGains
        #expect(clamped[0] == 0, "NaN should be replaced with 0, got \(clamped[0])")
        #expect(clamped[1] == 5.0)
    }

    @Test("clampedGains handles infinity by replacing with 0")
    func clampedGainsInfinity() {
        let eq = EQSettings(bandGains: [.infinity, -.infinity, 0, 0, 0, 0, 0, 0, 0, 0])
        let clamped = eq.clampedGains
        #expect(clamped[0] == 0, "+inf should become 0")
        #expect(clamped[1] == 0, "-inf should become 0")
    }

    @Test("isEnabled defaults to true")
    func isEnabledDefault() {
        let eq = EQSettings()
        #expect(eq.isEnabled)
    }

    @Test("flat preset is equal to default init")
    func flatEqualsDefault() {
        #expect(EQSettings.flat == EQSettings())
    }
}

// MARK: - EQSettings — Frequencies

@Suite("EQSettings — Frequency constants")
struct EQSettingsFrequencyTests {

    @Test("frequencies has exactly 10 entries matching bandCount")
    func frequencyCount() {
        #expect(EQSettings.frequencies.count == EQSettings.bandCount)
    }

    @Test("Frequencies are strictly increasing (monotonic)")
    func frequenciesMonotonic() {
        for i in 1..<EQSettings.frequencies.count {
            #expect(EQSettings.frequencies[i] > EQSettings.frequencies[i - 1],
                    "Frequency[\(i)] (\(EQSettings.frequencies[i])) should be > frequency[\(i-1)] (\(EQSettings.frequencies[i-1]))")
        }
    }

    @Test("All frequencies are within audible range (20 Hz - 20 kHz)")
    func frequenciesInAudibleRange() {
        for (index, freq) in EQSettings.frequencies.enumerated() {
            #expect(freq >= 20 && freq <= 20000,
                    "Frequency[\(index)] = \(freq) Hz is outside audible range")
        }
    }

    @Test("Frequencies match ISO 10-band standard (31.25 Hz to 16 kHz)")
    func frequenciesMatchISO() {
        let expected: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        #expect(EQSettings.frequencies == expected)
    }
}

// MARK: - EQSettings — Codable Round-Trip

@Suite("EQSettings — JSON serialization")
struct EQSettingsCodableTests {

    @Test("Round-trip encoding preserves all fields")
    func roundTrip() throws {
        let original = EQSettings(bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], isEnabled: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding with missing bandGains defaults to zeros")
    func missingBandGains() throws {
        let json = #"{"isEnabled": true}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        #expect(decoded.bandGains.count == EQSettings.bandCount)
        #expect(decoded.bandGains.allSatisfy { $0 == 0 })
    }

    @Test("Decoding with missing isEnabled defaults to true")
    func missingIsEnabled() throws {
        let json = #"{"bandGains": [0,0,0,0,0,0,0,0,0,0]}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        #expect(decoded.isEnabled)
    }

    @Test("Decoding with short bandGains array pads with zeros")
    func shortBandGainsPads() throws {
        let json = #"{"bandGains": [5.0, 3.0]}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        #expect(decoded.bandGains.count == EQSettings.bandCount)
        #expect(decoded.bandGains[0] == 5.0)
        #expect(decoded.bandGains[1] == 3.0)
        #expect(decoded.bandGains[2] == 0)
    }
}
