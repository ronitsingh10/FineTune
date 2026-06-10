// FineTune/Shortcuts/ShortcutCodable.swift
import Foundation
import KeyboardShortcuts

/// A persistence-stable representation of a global keyboard shortcut.
///
/// This wraps the `(carbonKeyCode, carbonModifiers)` pair stored by
/// `KeyboardShortcuts.Shortcut` so `settings.json` does not depend on the
/// library's internal `Codable` shape — if KeyboardShortcuts ever changes its
/// own `Codable` representation, our settings file remains compatible.
nonisolated struct ShortcutCodable: Codable, Equatable, Hashable, Sendable {
    var keyCode: Int
    var modifiers: UInt

    init(keyCode: Int, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static func from(_ shortcut: KeyboardShortcuts.Shortcut) -> ShortcutCodable {
        ShortcutCodable(
            keyCode: shortcut.carbonKeyCode,
            modifiers: UInt(shortcut.carbonModifiers)
        )
    }

    var keyboardShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: keyCode,
            carbonModifiers: Int(modifiers)
        )
    }
}
