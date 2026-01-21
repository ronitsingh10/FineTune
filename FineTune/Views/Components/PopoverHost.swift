// FineTune/Views/Components/PopoverHost.swift
import SwiftUI
import AppKit

/// A dropdown panel without arrow using NSPanel
/// Uses child window relationship for proper dismissal behavior
struct PopoverHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
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
                context.coordinator.showPanel(from: nsView, content: content)
            }
        } else {
            context.coordinator.dismissPanel()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    class Coordinator: NSObject {
        @Binding var isPresented: Bool
        var panel: NSPanel?
        var localEventMonitor: Any?
        var globalEventMonitor: Any?
        var appDeactivateObserver: NSObjectProtocol?

        init(isPresented: Binding<Bool>) {
            self._isPresented = isPresented
        }

        func showPanel<V: View>(from parentView: NSView, content: () -> V) {
            guard let parentWindow = parentView.window else { return }

            // Create borderless panel that doesn't steal focus
            let panel = NSPanel(
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

            panel.becomesKeyOnlyIfNeeded = true

            // Create hosting view with content, forcing dark color scheme
            let hostingView = NSHostingView(rootView: content().preferredColorScheme(.dark))
            hostingView.frame.size = hostingView.fittingSize
            panel.contentView = hostingView
            panel.setContentSize(hostingView.fittingSize)

            // Position below trigger
            let parentFrame = parentView.convert(parentView.bounds, to: nil)
            let screenFrame = parentWindow.convertToScreen(parentFrame)
            let panelOrigin = NSPoint(
                x: screenFrame.origin.x,
                y: screenFrame.origin.y - panel.frame.height - 4
            )
            panel.setFrameOrigin(panelOrigin)

            // KEY: Add as child window - links to parent's event stream
            parentWindow.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
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

            // Global monitor: clicks in OTHER apps (dismisses panel)
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissPanel()
            }

            // Dismiss when app loses focus (Command-Tab, click other app, quit, etc.)
            appDeactivateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.dismissPanel()
            }
        }

        func dismissPanel() {
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
            if isPresented {
                isPresented = false
            }
        }

        deinit {
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
