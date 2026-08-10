// FineTune/Shortcuts/FluidMenuBarExtraIntrospection.swift
import AppKit

/// Shared `NSApp.windows` + KVC introspection helpers for locating FineTune's
/// `FluidMenuBarExtra`-backed status item and panel from outside the SwiftUI
/// scene chain. See `MenuBarPopupController`'s doc comment for why this
/// technique is safe and package-agnostic.
@MainActor
enum FluidMenuBarExtraIntrospection {
    /// macOS renamed the concrete `NSStatusItem` runtime class in the macOS 26
    /// scene-based status item refactor. Keep both branches so we work across
    /// the deployment-target floor (14.2) up through current 26.x.
    static var concreteStatusItemClassName: String {
        if #available(macOS 26.0, *) {
            return "NSSceneStatusItem"
        }
        return "NSStatusItem"
    }

    static func findStatusItem(accessibilityTitle: String) -> NSStatusItem? {
        let concreteName = concreteStatusItemClassName

        return NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap(extractStatusItem(from:))
            // Multi-display setups with "Displays have separate Spaces" enabled produce
            // one NSStatusBarWindow per display; the inactive ones return an
            // `NSStatusItemReplicant` (a subclass of NSStatusItem). Skip replicants —
            // we only want the canonical item that owns the real button.
            .filter { $0.className == concreteName }
            .first { $0.button?.accessibilityTitle() == accessibilityTitle }
    }

    /// Locates the `FluidMenuBarExtraWindow` panel among `NSApp.windows`. The
    /// type itself isn't `public` in the FluidMenuBarExtra module, so we match
    /// by class name rather than importing/casting to the concrete type.
    static func findPanel() -> NSPanel? {
        NSApp.windows.first { $0.className.contains("FluidMenuBarExtraWindow") } as? NSPanel
    }

    /// Pulls the `statusItem` private key off an `NSStatusBarWindow`.
    /// KVC is the primary path; `Mirror` is a defensive fallback in case Apple
    /// changes how the property is exposed in a future macOS release.
    private static func extractStatusItem(from window: NSWindow) -> NSStatusItem? {
        if let item = window.value(forKey: "statusItem") as? NSStatusItem {
            return item
        }
        return Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
    }
}
