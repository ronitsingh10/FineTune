// FineTune/Views/DesignSystem/AppearancePreference+SwiftUI.swift
import SwiftUI
import AppKit

extension AppearancePreference {
    /// `.system` resolves concrete because `.preferredColorScheme(nil)` doesn't
    /// re-propagate after a previously-locked value (HwS forum 23260, Apple
    /// Forums 658818). Live system flips are picked up via `WindowAppearanceBridge`.
    @MainActor
    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }
}
