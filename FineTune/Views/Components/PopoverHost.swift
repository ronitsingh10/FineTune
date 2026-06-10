// FineTune/Views/Components/PopoverHost.swift
import SwiftUI
import AppKit

/// Borderless panels return `canBecomeKey == false` by default,
/// which prevents text fields from receiving focus/keyboard input.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

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

            // Position below trigger
            let parentFrame = parentView.convert(parentView.bounds, to: nil)
            let screenFrame = parentWindow.convertToScreen(parentFrame)
            let panelOrigin = NSPoint(
                x: screenFrame.origin.x,
                y: screenFrame.origin.y - panel.frame.height - 4
            )
            panel.setFrameOrigin(panelOrigin)

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

            // Get trigger button frame in screen coordinates
            let triggerFrame = parentWindow.convertToScreen(parentView.convert(parentView.bounds, to: nil))

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
            // Remove child window relationship
            if let panel = panel, let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel?.orderOut(nil)
            panel = nil
            hostingView = nil

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
        }
    }
}
