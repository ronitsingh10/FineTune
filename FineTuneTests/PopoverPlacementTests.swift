// FineTuneTests/PopoverPlacementTests.swift
import Testing
import AppKit
@testable import FineTune

@Suite("PopoverPlacement")
struct PopoverPlacementTests {
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1680, height: 1025)
    private let panelSize = NSSize(width: 210, height: 300)

    @Test("A trigger with room around it opens downward, left-aligned")
    func regularTriggerOpensDownward() {
        let trigger = NSRect(x: 700, y: 500, width: 40, height: 24)

        let origin = PopoverPlacement.origin(
            triggerFrame: trigger,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        #expect(origin.x == 700)
        #expect(origin.y == 196)
    }

    @Test("A trigger near the right edge flips the panel to trailing alignment")
    func rightEdgeTriggerFlipsPanel() {
        let trigger = NSRect(x: 1500, y: 500, width: 40, height: 24)

        let origin = PopoverPlacement.origin(
            triggerFrame: trigger,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        // Right edge of the panel lines up with the trigger's right edge.
        #expect(origin.x == 1330)
        #expect(origin.x + panelSize.width <= visibleFrame.maxX - PopoverPlacement.edgeMargin)
        #expect(origin.y == 196)
    }

    @Test("A trigger near the bottom opens above instead of under the Dock")
    func bottomTriggerFlipsAbove() {
        let trigger = NSRect(x: 400, y: 30, width: 40, height: 24)

        let origin = PopoverPlacement.origin(
            triggerFrame: trigger,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        #expect(origin.x == 400)
        #expect(origin.y == 58)
    }

    @Test("A panel wider than the screen keeps its left edge on screen")
    func oversizedPanelKeepsLeftEdgeVisible() {
        let trigger = NSRect(x: 100, y: 500, width: 40, height: 24)

        let origin = PopoverPlacement.origin(
            triggerFrame: trigger,
            panelSize: NSSize(width: 2000, height: 300),
            visibleFrame: visibleFrame
        )

        #expect(origin.x == PopoverPlacement.edgeMargin)
    }

    @Test("A panel taller than the screen keeps its bottom edge on screen")
    func oversizedPanelKeepsBottomEdgeVisible() {
        let trigger = NSRect(x: 400, y: 500, width: 40, height: 24)

        let origin = PopoverPlacement.origin(
            triggerFrame: trigger,
            panelSize: NSSize(width: 210, height: 2000),
            visibleFrame: visibleFrame
        )

        #expect(origin.y == PopoverPlacement.edgeMargin)
    }
}
