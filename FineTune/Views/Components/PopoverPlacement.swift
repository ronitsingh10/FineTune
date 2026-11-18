// FineTune/Views/Components/PopoverPlacement.swift
import AppKit

/// Screen-edge placement for the panels hosted by `PopoverHost`.
///
/// Dropdowns normally left-align with their trigger and open downward. That
/// runs off the right edge of the display for controls inside FineTune's own
/// popup, which sits under a menu-bar icon on the right (for example the
/// per-app device picker). Near the right edge the panel flips to trailing
/// alignment; near the bottom it flips above the trigger instead of sliding
/// under the Dock. Absolute clamping is the last resort, so the whole panel is
/// always on screen.
enum PopoverPlacement {
    /// Gap kept between the panel and the screen edges.
    static let edgeMargin: CGFloat = 8

    /// Gap kept between the panel and its trigger.
    static let triggerGap: CGFloat = 4

    static func origin(
        triggerFrame: NSRect,
        panelSize: CGSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let width = panelSize.width
        let height = panelSize.height
        let margin = min(edgeMargin, max(0, min(visibleFrame.width, visibleFrame.height) / 4))

        // Horizontal: align leading edges, then flip to the trigger's trailing
        // edge when the panel would leave the screen.
        var x = triggerFrame.minX
        if x + width > visibleFrame.maxX - margin {
            x = triggerFrame.maxX - width
        }
        let maxX = max(visibleFrame.minX + margin, visibleFrame.maxX - width - margin)
        x = min(max(x, visibleFrame.minX + margin), maxX)

        // Vertical: below the trigger by default; above it when there is no
        // room below (trigger near the Dock or the bottom edge).
        var y = triggerFrame.minY - height - triggerGap
        if y < visibleFrame.minY + margin {
            let above = triggerFrame.maxY + triggerGap
            if above + height <= visibleFrame.maxY - margin {
                y = above
            }
        }
        let maxY = max(visibleFrame.minY + margin, visibleFrame.maxY - height - margin)
        y = min(max(y, visibleFrame.minY + margin), maxY)

        return NSPoint(x: x, y: y)
    }
}
