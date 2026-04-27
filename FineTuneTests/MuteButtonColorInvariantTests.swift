// FineTuneTests/MuteButtonColorInvariantTests.swift
// Pins DesignTokens.Colors.mutedIndicator to a recognizably-red value
// in both appearances. The view-level invariant ("muted state always
// wins over hover and selection in BaseMuteButton.buttonColor") is
// enforced by the if-else order in MuteButton.swift; this test guards
// the token that backs it so a future "calmer red" tweak cannot
// silently weaken the muted-state read.
//
// Equality against `NSColor.systemRed.withAlphaComponent(0.85)` would
// be tighter but fails: SwiftUI's `.opacity(0.85)` and AppKit's
// `.withAlphaComponent(0.85)` go through slightly different conversion
// paths that diverge in the green channel by ~0.04 in sRGB. The
// red-dominance assertions below capture the visual contract without
// pinning to that conversion accident.

import Testing
import SwiftUI
import AppKit
@testable import FineTune

@Suite("MuteButton — Color invariant")
@MainActor
struct MuteButtonColorInvariantTests {

    /// Resolves a SwiftUI Color to an NSColor in the given appearance.
    private func resolve(_ color: Color, appearance: NSAppearance) -> NSColor {
        var resolved: NSColor = .clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return resolved
    }

    private static let aqua = NSAppearance(named: .aqua)!
    private static let darkAqua = NSAppearance(named: .darkAqua)!

    @Test("mutedIndicator is red-dominant in light")
    func mutedIndicatorIsRedDominantLight() {
        let c = resolve(DesignTokens.Colors.mutedIndicator, appearance: Self.aqua)
        // Red strongly above green/blue; alpha around 0.85 (the token's intent).
        #expect(c.redComponent > 0.7)
        #expect(c.redComponent - c.greenComponent > 0.4)
        #expect(c.redComponent - c.blueComponent > 0.4)
        #expect(abs(c.alphaComponent - 0.85) < 0.02)
    }

    @Test("mutedIndicator is red-dominant in dark")
    func mutedIndicatorIsRedDominantDark() {
        let c = resolve(DesignTokens.Colors.mutedIndicator, appearance: Self.darkAqua)
        #expect(c.redComponent > 0.7)
        #expect(c.redComponent - c.greenComponent > 0.4)
        #expect(c.redComponent - c.blueComponent > 0.4)
        #expect(abs(c.alphaComponent - 0.85) < 0.02)
    }
}
