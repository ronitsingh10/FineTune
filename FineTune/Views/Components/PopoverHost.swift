// FineTune/Views/Components/PopoverHost.swift
import SwiftUI
import AppKit

/// Borderless panels return `canBecomeKey == false` by default,
/// which prevents text fields from receiving focus/keyboard input.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Vertical gap between the trigger and the panel.
private let popoverTriggerGap: CGFloat = 4
/// Minimum distance kept between the panel and the screen's visible edges.
private let popoverScreenMargin: CGFloat = 8

/// A dropdown panel without arrow using NSPanel
/// Uses child window relationship for proper dismissal behavior
struct PopoverHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// SwiftUI color-scheme override applied to the hosted root view. `nil`
    /// means "follow environment" (System mode).
    let preferredColorScheme: ColorScheme?
    /// AppKit appearance applied to the panel itself. `nil` inherits from the
    /// application's effective appearance (System mode).
    let nsAppearance: NSAppearance?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    // Clean up when view is removed from hierarchy (e.g., app row disappears)
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismissPanel()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            if context.coordinator.panel == nil {
                context.coordinator.showPanel(
                    from: nsView,
                    content: content,
                    preferredColorScheme: preferredColorScheme,
                    nsAppearance: nsAppearance
                )
            } else {
                // Update content when state changes while panel is open
                context.coordinator.updateContent(
                    content,
                    preferredColorScheme: preferredColorScheme,
                    nsAppearance: nsAppearance
                )
            }
        } else {
            context.coordinator.dismissPanel()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    @MainActor
    class Coordinator: NSObject {
        @Binding var isPresented: Bool
        var panel: NSPanel?
        var hostingView: NSHostingView<AnyView>?
        var localEventMonitor: Any?
        var globalEventMonitor: Any?
        var appDeactivateObserver: NSObjectProtocol?
        weak var parentWindow: NSWindow?
        /// The view the panel is anchored to. Its screen frame is recomputed on
        /// every placement so the panel follows the parent window if it moves.
        private weak var triggerView: NSView?
        /// Last known screen-space frame of the trigger; fallback when the view
        /// is no longer in a window.
        private var triggerScreenFrame: NSRect = .zero
        private var resizeObserver: NSObjectProtocol?

        private func currentTriggerScreenFrame() -> NSRect {
            if let view = triggerView, let window = view.window {
                triggerScreenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
            }
            return triggerScreenFrame
        }

        init(isPresented: Binding<Bool>) {
            self._isPresented = isPresented
        }

        func showPanel<V: View>(
            from parentView: NSView,
            content: () -> V,
            preferredColorScheme: ColorScheme?,
            nsAppearance: NSAppearance?
        ) {
            guard let parentWindow = parentView.window else { return }
            self.parentWindow = parentWindow

            // Create borderless panel that can become key for text field input
            let panel = KeyablePanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .popUpMenu
            panel.hasShadow = true
            panel.collectionBehavior = [.fullScreenAuxiliary]
            // Apply appearance before any drawing so NSVisualEffectView picks
            // it up on first render. `nil` inherits from the application.
            panel.appearance = nsAppearance

            panel.becomesKeyOnlyIfNeeded = false

            // Create hosting view with content, applying the resolved color scheme.
            // Use AnyView to allow rootView updates without replacing the hosting view.
            let hosting: NSHostingView<AnyView> = NSHostingView(rootView: AnyView(content().preferredColorScheme(preferredColorScheme)))
            hosting.frame.size = hosting.fittingSize
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            self.hostingView = hosting

            // Position below trigger, kept on screen (see positionPanel). NSHostingView
            // may resize the panel asynchronously through Auto Layout, so also
            // re-run the placement whenever the panel's size actually changes.
            triggerView = parentView
            positionPanel(panel, size: hosting.fittingSize)
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel else { return }
                    self.positionPanel(panel, size: panel.frame.size)
                }
            }

            // Add as child window - links to parent's event stream
            parentWindow.addChildWindow(panel, ordered: .above)

            // Make panel key so text fields can receive focus.
            // Temporarily suppress the parent's delegate to prevent
            // FluidMenuBarExtra from dismissing the popup on resign-key.
            let savedDelegate = parentWindow.delegate
            parentWindow.delegate = nil
            panel.makeKeyAndOrderFront(nil)
            parentWindow.delegate = savedDelegate

            self.panel = panel

            // Trigger button frame in screen coordinates (captured by positionPanel above)
            let triggerFrame = triggerScreenFrame

            // Local monitor: clicks within our app (outside panel AND outside trigger)
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.panel else { return event }
                let mouseLocation = NSEvent.mouseLocation
                let isInPanel = panel.frame.contains(mouseLocation)
                let isInTrigger = triggerFrame.contains(mouseLocation)
                // Only dismiss if click is outside both panel and trigger button
                // Let the trigger button handle its own clicks (toggle behavior)
                if !isInPanel && !isInTrigger {
                    self.dismissPanel()
                }
                return event  // Don't consume
            }

            // Global monitor: clicks in OTHER apps (dismisses panel + parent)
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissPanel(reKeyParent: false)
            }

            // Dismiss when app loses focus (Command-Tab, click other app, quit, etc.)
            appDeactivateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismissPanel(reKeyParent: false)
                }
            }
        }

        /// Places the panel just below the trigger, left-aligned with it, then keeps
        /// it fully on screen. Icon-only triggers sit at the far right of the popup,
        /// and the popup itself hugs the menu bar icon near the screen edge, so a
        /// left-aligned dropdown routinely ran past the right edge and was clipped
        /// (device names unreadable, "Multi" toggle unreachable). When the panel
        /// would overflow to the right it is right-aligned with the trigger instead;
        /// when there is no room below, it flips above. Coordinates are clamped to
        /// the visible frame of the screen that contains the trigger.
        private func positionPanel(_ panel: NSPanel, size: NSSize) {
            let trigger = currentTriggerScreenFrame()
            let gap = popoverTriggerGap
            var origin = NSPoint(x: trigger.minX, y: trigger.minY - size.height - gap)

            let triggerCenter = NSPoint(x: trigger.midX, y: trigger.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(triggerCenter) }
                ?? NSScreen.screens.first { $0.frame.intersects(trigger) }
                ?? parentWindow?.screen
                ?? NSScreen.main
            guard let visible = screen?.visibleFrame else {
                panel.setFrameOrigin(origin)
                return
            }
            let margin = popoverScreenMargin

            if origin.x + size.width > visible.maxX - margin {
                origin.x = trigger.maxX - size.width  // right-align with the trigger
            }
            origin.x = max(visible.minX + margin, min(origin.x, visible.maxX - margin - size.width))

            if origin.y < visible.minY + margin,
               trigger.maxY + gap + size.height <= visible.maxY - margin {
                origin.y = trigger.maxY + gap  // flip above the trigger
            }
            origin.y = max(origin.y, visible.minY + margin)

            panel.setFrameOrigin(origin)
        }

        func updateContent<V: View>(
            _ content: () -> V,
            preferredColorScheme: ColorScheme?,
            nsAppearance: NSAppearance?
        ) {
            guard let hostingView = hostingView else { return }
            // Re-apply appearance in case the preference changed while the
            // panel is open. Setting to the same value is a no-op.
            panel?.appearance = nsAppearance
            // Update existing hosting view's rootView instead of replacing it
            // This allows SwiftUI to perform efficient diffing without flickering
            hostingView.rootView = AnyView(content().preferredColorScheme(preferredColorScheme))
            // Resize panel if content size changed
            let newSize = hostingView.fittingSize
            if let panel = panel, panel.frame.size != newSize {
                panel.setContentSize(newSize)
                // setContentSize keeps the bottom-left origin, so a panel that grew
                // would creep upward over its trigger (and could leave the screen).
                positionPanel(panel, size: newSize)
            }
        }

        /// - Parameter reKeyParent: When `true`, restores key status to the parent
        ///   window (normal dismiss, e.g. user selected a profile). When `false`,
        ///   re-keys then resigns the parent so FluidMenuBarExtra dismisses it too
        ///   (external click or app deactivation).
        func dismissPanel(reKeyParent: Bool = true) {
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
                localEventMonitor = nil
            }
            if let monitor = globalEventMonitor {
                NSEvent.removeMonitor(monitor)
                globalEventMonitor = nil
            }
            if let observer = appDeactivateObserver {
                NotificationCenter.default.removeObserver(observer)
                appDeactivateObserver = nil
            }
            if let observer = resizeObserver {
                NotificationCenter.default.removeObserver(observer)
                resizeObserver = nil
            }
            // Remove child window relationship
            if let panel = panel, let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel?.orderOut(nil)
            panel = nil
            hostingView = nil
            triggerView = nil

            if let parentWindow = parentWindow {
                if reKeyParent {
                    // Restore key status — parent popup stays visible
                    parentWindow.makeKey()
                } else {
                    // External dismiss — re-key then resign so FluidMenuBarExtra
                    // runs its standard dismiss animation
                    parentWindow.makeKey()
                    parentWindow.resignKey()
                }
            }
            parentWindow = nil

            if isPresented {
                isPresented = false
            }
        }

        isolated deinit {
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = globalEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let observer = appDeactivateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = resizeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
