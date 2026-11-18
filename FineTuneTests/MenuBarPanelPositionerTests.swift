// FineTuneTests/MenuBarPanelPositionerTests.swift
import Testing
import AppKit
@testable import FineTune

@Suite("MenuBarPanelGeometry")
struct MenuBarPanelPositionerTests {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1680, height: 1050)
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1680, height: 1025)

    @Test("A status item in the menu-bar band is a settled anchor")
    func settledAnchorInMenuBar() {
        let anchor = NSRect(x: 1135, y: 1026, width: 32, height: 24)
        #expect(MenuBarPanelGeometry.isAnchorSettled(anchor, screenFrame: screenFrame))
    }

    @Test("The cold-launch (0,0) anchor is not settled")
    func zeroAnchorIsNotSettled() {
        let anchor = NSRect(x: 0, y: 0, width: 32, height: 24)
        #expect(!MenuBarPanelGeometry.isAnchorSettled(anchor, screenFrame: screenFrame))
    }

    @Test("A parked status-item window frame falls back to the accessibility frame")
    func parkedWindowFrameUsesAccessibilityFrame() {
        // Observed on a cold launch: the window reports its off-screen parking
        // spot while the button's accessibility frame is already on the menu bar.
        let parked = NSRect(x: 0, y: -24, width: 32, height: 24)
        let axFrame = NSRect(x: 1134, y: 1026, width: 34, height: 24)

        let anchor = MenuBarPanelGeometry.settledAnchor(
            windowFrame: parked,
            accessibilityFrame: axFrame,
            screenFrame: screenFrame
        )

        #expect(anchor == axFrame)
    }

    @Test("A settled window frame wins over the accessibility frame")
    func settledWindowFrameTakesPriority() {
        let windowFrame = NSRect(x: 1135, y: 1026, width: 32, height: 24)
        let axFrame = NSRect(x: 1134, y: 1026, width: 34, height: 24)

        let anchor = MenuBarPanelGeometry.settledAnchor(
            windowFrame: windowFrame,
            accessibilityFrame: axFrame,
            screenFrame: screenFrame
        )

        #expect(anchor == windowFrame)
    }

    @Test("No settled source yields no anchor")
    func noSettledSourceYieldsNil() {
        let parked = NSRect(x: 0, y: -24, width: 32, height: 24)

        let anchor = MenuBarPanelGeometry.settledAnchor(
            windowFrame: parked,
            accessibilityFrame: parked,
            screenFrame: screenFrame
        )

        #expect(anchor == nil)
    }

    @Test("An empty anchor is not settled")
    func emptyAnchorIsNotSettled() {
        #expect(!MenuBarPanelGeometry.isAnchorSettled(.zero, screenFrame: screenFrame))
    }

    @Test("A settled anchor places the panel flush below the icon")
    func settledAnchorLeftAlignment() {
        let anchor = NSRect(x: 1135, y: 1026, width: 32, height: 24)
        let frame = MenuBarPanelGeometry.frame(
            panelSize: NSSize(width: 510, height: 543),
            anchorFrame: anchor,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame.origin.x == 1133)
        #expect(frame.origin.y == 483)
        #expect(frame.size == NSSize(width: 510, height: 543))
    }

    @Test("A status item near the right edge flips the panel to right alignment")
    func settledAnchorNearRightEdge() {
        let anchor = NSRect(x: 1640, y: 1026, width: 32, height: 24)
        let frame = MenuBarPanelGeometry.frame(
            panelSize: NSSize(width: 510, height: 543),
            anchorFrame: anchor,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame.maxX == 1672)
        #expect(frame.origin.y == 483)
    }

    @Test("An unsettled anchor falls back to the visible top-right corner")
    func unsettledAnchorFallsBackToTopRight() {
        let anchor = NSRect(x: 0, y: 0, width: 32, height: 24)
        let frame = MenuBarPanelGeometry.frame(
            panelSize: NSSize(width: 510, height: 543),
            anchorFrame: anchor,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame.origin.x == 1162)
        #expect(frame.origin.y == 482)
    }

    @Test("A nil anchor uses the same visible top-right fallback")
    func nilAnchorFallsBackToTopRight() {
        let frame = MenuBarPanelGeometry.frame(
            panelSize: NSSize(width: 510, height: 543),
            anchorFrame: nil,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame.origin.x == 1162)
        #expect(frame.origin.y == 482)
    }

    @Test("A panel taller than the screen stays anchored at the bottom margin")
    func oversizedPanelIsClampedAboveBottomEdge() {
        let frame = MenuBarPanelGeometry.frame(
            panelSize: NSSize(width: 400, height: 1200),
            anchorFrame: nil,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame.origin.y == 8)
        #expect(frame.size.height == 1200)
    }

    @Test("A panel wider than the screen keeps its left edge on screen")
    func oversizedPanelKeepsLeftEdgeVisible() {
        let frame = MenuBarPanelGeometry.frame(
            panelSize: NSSize(width: 2000, height: 543),
            anchorFrame: nil,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame.origin.x == 8)
        #expect(frame.size.width == 2000)
    }
}
