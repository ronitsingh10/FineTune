// FineTune/Settings/Types/SettingsUITypes.swift
import Foundation
import AppKit

// MARK: - App-Wide Settings Enums

enum AppLanguagePreference: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case system
    case arabicSaudiArabia = "ar-SA"
    case bengaliBangladesh = "bn-BD"
    case catalan = "ca"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutchNetherlands = "nl-NL"
    case englishAustralia = "en-AU"
    case englishCanada = "en-CA"
    case englishUnitedKingdom = "en-GB"
    case englishUnitedStates = "en-US"
    case finnish = "fi"
    case frenchFrance = "fr-FR"
    case frenchCanada = "fr-CA"
    case germanGermany = "de-DE"
    case greek = "el"
    case gujaratiIndia = "gu-IN"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case kannadaIndia = "kn-IN"
    case korean = "ko"
    case malay = "ms"
    case malayalamIndia = "ml-IN"
    case marathiIndia = "mr-IN"
    case norwegianBokmal = "nb"
    case odiaIndia = "or-IN"
    case polish = "pl"
    case portugueseBrazil = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case punjabiIndia = "pa-IN"
    case romanian = "ro"
    case russian = "ru"
    case slovak = "sk"
    case slovenianSlovenia = "sl-SI"
    case spanishMexico = "es-MX"
    case spanishSpain = "es-ES"
    case swedish = "sv"
    case tamilIndia = "ta-IN"
    case teluguIndia = "te-IN"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case urduPakistan = "ur-PK"
    case vietnamese = "vi"

    var id: String { rawValue }

    var description: String {
        guard let localeIdentifier else { return L10n.string("System") }
        return Locale.autoupdatingCurrent.localizedString(forIdentifier: localeIdentifier) ?? fallbackDisplayName
    }

    private var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }

    private var appleLanguages: [String]? {
        localeIdentifier.map { [$0] }
    }

    private var fallbackDisplayName: String {
        switch self {
        case .system: return "System"
        case .arabicSaudiArabia: return "Arabic (Saudi Arabia)"
        case .bengaliBangladesh: return "Bengali (Bangladesh)"
        case .catalan: return "Catalan"
        case .simplifiedChinese: return "Chinese (Simplified)"
        case .traditionalChinese: return "Chinese (Traditional)"
        case .croatian: return "Croatian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutchNetherlands: return "Dutch (Netherlands)"
        case .englishAustralia: return "English (Australia)"
        case .englishCanada: return "English (Canada)"
        case .englishUnitedKingdom: return "English (U.K.)"
        case .englishUnitedStates: return "English (U.S.)"
        case .finnish: return "Finnish"
        case .frenchFrance: return "French (France)"
        case .frenchCanada: return "French (Canada)"
        case .germanGermany: return "German (Germany)"
        case .greek: return "Greek"
        case .gujaratiIndia: return "Gujarati (India)"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .kannadaIndia: return "Kannada (India)"
        case .korean: return "Korean"
        case .malay: return "Malay"
        case .malayalamIndia: return "Malayalam (India)"
        case .marathiIndia: return "Marathi (India)"
        case .norwegianBokmal: return "Norwegian Bokmål"
        case .odiaIndia: return "Odia (India)"
        case .polish: return "Polish"
        case .portugueseBrazil: return "Portuguese (Brazil)"
        case .portuguesePortugal: return "Portuguese (Portugal)"
        case .punjabiIndia: return "Punjabi (India)"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .slovak: return "Slovak"
        case .slovenianSlovenia: return "Slovenian (Slovenia)"
        case .spanishMexico: return "Spanish (Mexico)"
        case .spanishSpain: return "Spanish (Spain)"
        case .swedish: return "Swedish"
        case .tamilIndia: return "Tamil (India)"
        case .teluguIndia: return "Telugu (India)"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .urduPakistan: return "Urdu (Pakistan)"
        case .vietnamese: return "Vietnamese"
        }
    }

    func apply(to defaults: UserDefaults = .standard) {
        if let appleLanguages {
            defaults.set(appleLanguages, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        defaults.synchronize()
    }
}

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default` = "Default"
    case speaker = "Speaker"
    case waveform = "Waveform"
    case equalizer = "Equalizer"

    var id: String { rawValue }

    var displayName: String {
        L10n.string(rawValue)
    }

    /// The icon name - either asset catalog name or SF Symbol
    var iconName: String {
        switch self {
        case .default: return "MenuBarIcon"
        case .speaker: return "speaker.wave.2.fill"
        case .waveform: return "waveform"
        case .equalizer: return "slider.vertical.3"
        }
    }

    /// Whether this uses an SF Symbol (vs asset catalog image)
    var isSystemSymbol: Bool {
        self != .default
    }
}

// MARK: - HUD Style

/// Style of the on-screen HUD shown when media keys drive FineTune's volume.
/// `.tahoe` renders a small top-right pill; `.classic` renders a center-bottom panel
/// with 16 segment tiles matching Apple's pre-Tahoe HUD aesthetic.
enum HUDStyle: String, Codable, CaseIterable, Identifiable {
    case tahoe
    case classic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tahoe: return L10n.string("Tahoe")
        case .classic: return L10n.string("Classic")
        }
    }
}

// MARK: - Appearance Preference

/// User preference for app appearance. `.system` follows macOS appearance live;
/// `.light` and `.dark` lock the override regardless of system setting.
enum AppearancePreference: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case system
    case light
    case dark

    var id: String { rawValue }

    var description: String {
        switch self {
        case .system: return L10n.string("System")
        case .light: return L10n.string("Light")
        case .dark: return L10n.string("Dark")
        }
    }
}

extension AppearancePreference {
    /// AppKit appearance override. `nil` means "inherit from window or app".
    /// Apply via `nsView.window?.appearance = value` for any `NSWindow`/`NSPanel`
    /// the app hosts (popup, popover, HUD).
    /// `.aqua` available since macOS 10.9; `.darkAqua` since 10.14.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Menu Bar Popup Size

enum MenuBarPopupSize: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var description: String {
        switch self {
        case .compact: return L10n.string("Compact")
        case .comfortable: return L10n.string("Comfortable")
        case .spacious: return L10n.string("Spacious")
        }
    }
}

struct PopupDimensions: Equatable {
    let width: CGFloat
    let contentPadding: CGFloat
    /// Ceiling on the scrollable body. Sized to stay within a 13" MacBook Air's
    /// usable height after the menu bar, since FluidMenuBarExtra does not clamp
    /// the popup against `screen.visibleFrame` vertically.
    let maxContentHeight: CGFloat
}

extension MenuBarPopupSize {
    var dimensions: PopupDimensions {
        switch self {
        case .compact:
            return PopupDimensions(
                width: 470,
                contentPadding: 12,
                maxContentHeight: 560
            )
        case .comfortable:
            return PopupDimensions(
                width: 510,
                contentPadding: 16,
                maxContentHeight: 660
            )
        case .spacious:
            return PopupDimensions(
                width: 560,
                contentPadding: 20,
                maxContentHeight: 760
            )
        }
    }
}

// MARK: - Volume Hotkey Step Size

enum VolumeHotkeyStep: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case coarse
    case normal
    case fine
    case extraFine

    var id: String { rawValue }

    var sliderDelta: Double {
        switch self {
        case .coarse:    return 1.0 / 8.0
        case .normal:    return 1.0 / 16.0
        case .fine:      return 1.0 / 32.0
        case .extraFine: return 1.0 / 64.0
        }
    }

    var description: String {
        switch self {
        case .coarse:    return L10n.string("Coarse (12.5%)")
        case .normal:    return L10n.string("Normal (6.25%)")
        case .fine:      return L10n.string("Fine (3.13%)")
        case .extraFine: return L10n.string("Extra-Fine (1.56%)")
        }
    }
}
