// FineTune/Utilities/L10n.swift
// Small helpers for localized strings that flow through plain String APIs.

import Foundation

enum L10n {
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg..., bundle: Bundle = .main) -> String {
        let format = string(key, bundle: bundle)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
