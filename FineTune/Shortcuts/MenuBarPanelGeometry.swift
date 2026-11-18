// FineTune/Shortcuts/MenuBarPanelGeometry.swift
import AppKit

/// Pure frame math shared with tests.
///
/// Cocoa coordinates: the origin is bottom-left, so a status item sits near
/// `screenFrame.maxY` and the panel hangs just below it.
enum MenuBarPanelGeometry {
    /// Margin kept between the panel and the left/right/bottom screen edges.
    static let edgeMargin: CGFloat = 8

    /// A settled status-item window sits in the menu-bar band at the top of its
    /// screen. The cold-launch race reports `(0, 0)`, which fails this check.
    static func isAnchorSettled(_ anchorFrame: NSRect, screenFrame: NSRect) -> Bool {
        guard !anchorFrame.isEmpty,
              anchorFrame.width > 0,
              anchorFrame.height > 0
        else { return false }

        let topBandHeight = min(100, screenFrame.height * 0.2)
        let topBand = NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - topBandHeight,
            width: screenFrame.width,
            height: topBandHeight
        )
        return topBand.contains(NSPoint(x: anchorFrame.midX, y: anchorFrame.midY))
    }

    /// Picks the first usable status-item anchor.
    ///
    /// `NSStatusBarWindow.frame` can report its parked `(0, -24)` position for
    /// several seconds after a cold launch, while the button's accessibility
    /// frame already points at the real menu-bar icon. Prefer whichever source
    /// has settled so the popup never falls back to the corner when the icon
    /// position is knowable.
    static func settledAnchor(
        windowFrame: NSRect?,
        accessibilityFrame: NSRect?,
        screenFrame: NSRect
    ) -> NSRect? {
        if let windowFrame, isAnchorSettled(windowFrame, screenFrame: screenFrame) {
            return windowFrame
        }
        if let accessibilityFrame, isAnchorSettled(accessibilityFrame, screenFrame: screenFrame) {
            return accessibilityFrame
        }
        return nil
    }

    static func frame(
        panelSize: CGSize,
        anchorFrame: NSRect?,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSRect {
        let width = max(panelSize.width, 1)
        let height = max(panelSize.height, 1)
        let margin = min(edgeMargin, max(0, visibleFrame.width / 4))

        let anchorIsUsable = anchorFrame.map {
            isAnchorSettled($0, screenFrame: screenFrame)
        } ?? false

        let x: CGFloat
        let y: CGFloat

        if let anchorFrame, anchorIsUsable {
            // Match the package's left alignment under the icon, but flip to
            // right alignment when the panel would otherwise run off-screen.
            var candidateX = anchorFrame.minX - 2
            if candidateX + width > visibleFrame.maxX - margin {
                candidateX = anchorFrame.maxX - width + 2
            }
            x = min(
                max(candidateX, visibleFrame.minX + margin),
                max(visibleFrame.minX + margin, visibleFrame.maxX - width - margin)
            )
            y = anchorFrame.minY - height
        } else {
            // Cold-launch fallback: pin the popup to the top-right corner so it
            // is visible even while the true status-item anchor is unavailable.
            x = max(visibleFrame.minX + margin, visibleFrame.maxX - width - margin)
            y = visibleFrame.maxY - height
        }

        // Keep the panel above the Dock and below the menu bar. The top clamp
        // uses screenFrame (not visibleFrame) so a valid anchor can sit flush
        // against the menu bar instead of leaving a one-point gap.
        let minY = visibleFrame.minY + margin
        let maxY = max(minY, screenFrame.maxY - height)
        let clampedY = min(max(y, minY), maxY)

        return NSRect(x: x, y: clampedY, width: width, height: height)
    }
}
