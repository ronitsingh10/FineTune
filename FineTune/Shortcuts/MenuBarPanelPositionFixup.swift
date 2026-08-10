// FineTune/Shortcuts/MenuBarPanelPositionFixup.swift
import AppKit
import os

/// Works around a `FluidMenuBarExtra` cold-launch race (GitHub #387): on some
/// multi-monitor / unusual-DPI setups, the package's very first internal
/// frame calculation for the menu-bar panel runs before AppKit has finished
/// assigning the status item's button window to its correct screen. The
/// panel's origin is then computed from an effectively-zero anchor frame and
/// lands at the screen's bottom-left corner instead of below the icon.
///
/// User-reported workarounds (drag the icon, or open the panel once on
/// another display first) all share one thing: they force a second internal
/// reposition pass after the status item's window has settled. This polls
/// for that settled state, then re-applies the correct frame to the panel
/// directly — reimplementing FluidMenuBarExtra's own "below the icon,
/// left-aligned, clamped to visibleFrame" placement, since the types and
/// methods that actually own that logic aren't public API.
@MainActor
enum MenuBarPanelPositionFixup {
    private static let logger = Logger(
        subsystem: "com.finetuneapp.FineTune",
        category: "MenuBarPanelPositionFixup"
    )

    private static let maxAttempts = 20
    private static let pollInterval: TimeInterval = 0.1

    /// Starts polling for a settled status item + panel, then corrects the
    /// panel's frame once. Safe to call once at launch; a no-op fixup (frame
    /// already correct) is cheap and logs nothing.
    static func run(accessibilityTitle: String = "FineTune", attempt: Int = 0) {
        guard let statusItem = FluidMenuBarExtraIntrospection.findStatusItem(accessibilityTitle: accessibilityTitle),
              let button = statusItem.button,
              let anchorWindow = button.window else {
            retryOrGiveUp(accessibilityTitle: accessibilityTitle, attempt: attempt)
            return
        }

        let anchorFrame = anchorWindow.frame
        guard let screen = anchorWindow.screen, !anchorFrame.isEmpty else {
            retryOrGiveUp(accessibilityTitle: accessibilityTitle, attempt: attempt)
            return
        }

        guard let panel = FluidMenuBarExtraIntrospection.findPanel(), !panel.frame.isEmpty else {
            retryOrGiveUp(accessibilityTitle: accessibilityTitle, attempt: attempt)
            return
        }

        var correctedFrame = CGRect(origin: anchorFrame.origin, size: panel.frame.size)
        correctedFrame.origin.y -= correctedFrame.height

        if correctedFrame.maxX > screen.visibleFrame.maxX {
            correctedFrame.origin.x = screen.visibleFrame.maxX - correctedFrame.width
        }
        if correctedFrame.minX < screen.visibleFrame.minX {
            correctedFrame.origin.x = screen.visibleFrame.minX
        }

        // Only touch the panel if it's meaningfully off — avoids fighting a
        // frame FluidMenuBarExtra already positioned correctly, and avoids
        // nudging a panel the user has since dragged (if that ever becomes
        // possible) or is mid-open.
        guard abs(correctedFrame.origin.x - panel.frame.origin.x) > 1 ||
              abs(correctedFrame.origin.y - panel.frame.origin.y) > 1 else {
            return
        }

        logger.debug("Correcting cold-launch panel frame from \(panel.frame.debugDescription, privacy: .public) to \(correctedFrame.debugDescription, privacy: .public)")
        panel.setFrame(correctedFrame, display: panel.isVisible, animate: false)
    }

    private static func retryOrGiveUp(accessibilityTitle: String, attempt: Int) {
        guard attempt < maxAttempts else {
            logger.debug("Giving up after \(maxAttempts, privacy: .public) attempts; status item/panel never settled")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            run(accessibilityTitle: accessibilityTitle, attempt: attempt + 1)
        }
    }
}
