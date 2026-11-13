// FineTuneTests/PopoverPlacementTests.swift
// Verifies dropdown panels stay inside the parent window and the screen
// (issues #338, #464: output picker rendered past the popup's right edge).

import Testing
import AppKit
@testable import FineTune

@Suite("PopoverPlacement keeps dropdowns inside the window and screen")
struct PopoverPlacementTests {
    let window = NSRect(x: 1000, y: 500, width: 500, height: 400)
    let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    let panel = NSSize(width: 210, height: 150)

    @Test("Room on the right: left-aligned with the trigger, below it")
    func leftAligned() {
        let trigger = NSRect(x: 1050, y: 800, width: 100, height: 20)
        let origin = PopoverPlacement.origin(
            panelSize: panel, triggerFrame: trigger, windowFrame: window, visibleFrame: screen
        )
        #expect(origin.x == CGFloat(1050))
        #expect(origin.y == CGFloat(646))
    }

    @Test("Trigger near the window's right edge: right-aligned with the trigger")
    func rightAligned() {
        let trigger = NSRect(x: 1420, y: 800, width: 28, height: 28)
        let origin = PopoverPlacement.origin(
            panelSize: panel, triggerFrame: trigger, windowFrame: window, visibleFrame: screen
        )
        #expect(origin.x == CGFloat(1238))
        #expect(origin.x + panel.width <= window.maxX)
    }

    @Test("Panel never crosses the screen's right edge")
    func clampedToScreen() {
        let narrowScreen = NSRect(x: 0, y: 0, width: 1460, height: 1000)
        let trigger = NSRect(x: 1420, y: 800, width: 28, height: 28)
        let wideWindow = NSRect(x: 1000, y: 500, width: 600, height: 400)
        let origin = PopoverPlacement.origin(
            panelSize: panel, triggerFrame: trigger, windowFrame: wideWindow, visibleFrame: narrowScreen
        )
        #expect(origin.x + panel.width <= narrowScreen.maxX)
    }

    @Test("No room below on screen: flips above the trigger")
    func flipsAbove() {
        let trigger = NSRect(x: 1050, y: 60, width: 100, height: 20)
        let lowWindow = NSRect(x: 1000, y: 0, width: 500, height: 400)
        let origin = PopoverPlacement.origin(
            panelSize: panel, triggerFrame: trigger, windowFrame: lowWindow, visibleFrame: screen
        )
        #expect(origin.y == trigger.maxY + 4)
    }
}
