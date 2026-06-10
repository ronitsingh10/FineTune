// FineTune/Views/Components/ClickOutsideCoordinator.swift
import AppKit

/// Manages event monitors for detecting clicks outside a component.
/// Uses the same pattern as PopoverHost for reliable click-outside detection.
@MainActor
final class ClickOutsideCoordinator {
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appDeactivateObserver: NSObjectProtocol?

    /// Installs monitors to detect clicks outside the specified frame.
    /// - Parameters:
    ///   - excludingFrame: The frame (in screen coordinates) to exclude from triggering
    ///   - onClickOutside: Callback invoked when a click outside is detected
    func install(excludingFrame: CGRect, onClickOutside: @escaping @MainActor () -> Void) {
        removeMonitors()

        // Local monitor: clicks within our app (outside component)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard self != nil else { return event }
            let mouseLocation = NSEvent.mouseLocation
            if !excludingFrame.contains(mouseLocation) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onClickOutside() }
                }
            }
            return event
        }

        // Global monitor: clicks in OTHER apps
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard self != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onClickOutside() }
            }
        }

        // App deactivation: Command-Tab, clicking Dock, etc.
        appDeactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            MainActor.assumeIsolated { onClickOutside() }
        }
    }

    /// Removes all installed monitors and observers.
    func removeMonitors() {
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
    }

    isolated deinit {
        removeMonitors()
    }
}

/// Converts a SwiftUI global frame to screen coordinates for hit testing.
@MainActor
func screenFrame(from globalFrame: CGRect) -> CGRect {
    guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
        return .zero
    }
    let contentRect = window.contentRect(forFrameRect: window.frame)
    let windowY = contentRect.height - globalFrame.origin.y - globalFrame.height
    let windowRect = CGRect(
        x: globalFrame.origin.x,
        y: windowY,
        width: globalFrame.width,
        height: globalFrame.height
    )
    return window.convertToScreen(windowRect)
}
