// FineTune/Shortcuts/MenuBarPanelPositioner.swift
import AppKit
import os

/// Keeps the FluidMenuBarExtra popup pinned below the menu-bar icon.
///
/// `FluidMenuBarExtraStatusItem.setWindowFrame` anchors the panel to
/// `statusItem.button?.window.frame`. For several seconds after a cold launch
/// that window reports its parked off-screen frame (`(0, -24)` here) while the
/// status item is already visible in the menu bar. The package then places the
/// panel below the bottom-left corner of the display — usually completely
/// off-screen — and a later open can repeat the stale anchor, so the popup
/// appears to "sometimes go to the bottom left" and "sometimes get hidden".
///
/// This positioner reimplements the package's placement using the first settled
/// anchor available: the button's accessibility frame (which tracks the real
/// icon immediately), then the status-item window frame, and finally the
/// top-right of the active screen so the panel is always visible. It keeps
/// retrying while AppKit settles and re-anchors on every open, resize, and
/// screen change.
@MainActor
enum MenuBarPanelPositioner {
    private static let logger = Logger(
        subsystem: "com.finetuneapp.FineTune",
        category: "MenuBarPanelPositioner"
    )

    private static let accessibilityTitle = "FineTune"
    private static let retryInterval: TimeInterval = 0.1
    private static let maxRetryAttempts = 100

    private static var started = false
    private static var observers: [NSObjectProtocol] = []
    private static var localEventMonitor: Any?
    private static var retryTask: Task<Void, Never>?
    private static var retryAttempt = 0

    /// Starts observing the popup and the status item. Safe to call more than once.
    static func start() {
        guard !started else { return }
        started = true

        installStatusItemClickMonitor()
        installWindowObservers()

        // The status item and panel are created by the SwiftUI scene, which may
        // not have run yet. Retry until they exist, then keep the panel's saved
        // frame valid so the very first open is already in the right place.
        requestPositioning()
    }

    /// Recomputes and applies the panel frame immediately.
    static func requestPositioning() {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        positionOrRetry()
    }

    // MARK: - Observation

    private static func installWindowObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow,
                      isPopupWindow(window)
                else { return }
                requestPositioning()
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow,
                      isPopupWindow(window)
                else { return }
                // Content-size changes (EQ expansion, popup-size setting) also
                // run through the package's stale-anchor math.
                requestPositioning()
            }
        })

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                requestPositioning()
            }
        })
    }

    /// Watches clicks on our status item. The package handles the same event and
    /// shows the panel; correcting on the next main-loop turn lands after its
    /// frame math but before the panel is drawn.
    private static func installStatusItemClickMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            MainActor.assumeIsolated {
                guard let statusItemWindow = FluidMenuBarExtraIntrospection
                    .findStatusItem(accessibilityTitle: accessibilityTitle)?
                    .button?
                    .window,
                    event.window === statusItemWindow
                else { return }

                DispatchQueue.main.async {
                    requestPositioning()
                }
            }
            return event
        }
    }

    private static func isPopupWindow(_ window: NSWindow) -> Bool {
        window.className.contains("FluidMenuBarExtra")
            || window === FluidMenuBarExtraIntrospection.findPanel()
    }

    // MARK: - Positioning

    private static func positionOrRetry() {
        guard let panel = FluidMenuBarExtraIntrospection.findPanel() else {
            scheduleRetry()
            return
        }

        configure(panel)

        guard let screen = preferredScreen(panel: panel) else {
            scheduleRetry()
            return
        }

        let statusItem = FluidMenuBarExtraIntrospection.findStatusItem(
            accessibilityTitle: accessibilityTitle
        )
        let button = statusItem?.button
        let anchorFrame = MenuBarPanelGeometry.settledAnchor(
            windowFrame: button?.window?.frame,
            accessibilityFrame: button?.accessibilityFrame(),
            screenFrame: screen.frame
        )
        let anchorSettled = anchorFrame != nil

        let target = MenuBarPanelGeometry.frame(
            panelSize: panel.frame.size,
            anchorFrame: anchorFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )

        if panel.frame != target {
            logger.debug(
                "Positioning panel from \(panel.frame.debugDescription, privacy: .public) to \(target.debugDescription, privacy: .public)"
            )
            panel.setFrame(target, display: panel.isVisible, animate: false)
        }

        // While AppKit is still settling the status-item window, keep polling so
        // the fallback frame is replaced by the real icon anchor as soon as the
        // frame becomes usable.
        if !anchorSettled {
            scheduleRetry()
        }
    }

    private static func configure(_ panel: NSPanel) {
        // Re-assert the floating behavior every time: the popup must stay above
        // normal windows and follow the user to the active Space / full-screen app.
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .stationary,
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
    }

    private static func preferredScreen(panel: NSPanel) -> NSScreen? {
        let statusItem = FluidMenuBarExtraIntrospection.findStatusItem(
            accessibilityTitle: accessibilityTitle
        )
        let button = statusItem?.button
        let anchorWindow = button?.window

        // The accessibility frame tracks the real on-screen icon even while the
        // status-item window still reports its parked off-screen frame, so use it
        // first for multi-display setups.
        if let axFrame = button?.accessibilityFrame(),
           let screen = NSScreen.screens.first(where: {
               MenuBarPanelGeometry.isAnchorSettled(axFrame, screenFrame: $0.frame)
           }) {
            return screen
        }

        if let screen = anchorWindow?.screen,
           let anchorFrame = anchorWindow?.frame,
           MenuBarPanelGeometry.isAnchorSettled(anchorFrame, screenFrame: screen.frame) {
            return screen
        }

        // Even a stale anchor window still knows which display it belongs to.
        if let screen = anchorWindow?.screen {
            return screen
        }

        // Hotkey opens may run before the status-item window exists. Use the
        // display under the pointer, then the panel's current display.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        if let screen = panel.screen {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func scheduleRetry() {
        guard retryAttempt < maxRetryAttempts else { return }
        retryAttempt += 1

        retryTask?.cancel()
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            positionOrRetry()
        }
    }
}
