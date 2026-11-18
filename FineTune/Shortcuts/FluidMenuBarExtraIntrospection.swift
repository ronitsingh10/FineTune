// FineTune/Shortcuts/FluidMenuBarExtraIntrospection.swift
import AppKit

/// Shared `NSApp.windows` + KVC introspection for locating FineTune's
/// `FluidMenuBarExtra`-backed status item and panel from outside the SwiftUI
/// scene chain.
///
/// `FluidMenuBarExtraWindow` and `FluidMenuBarExtraStatusItem` are internal to
/// the package, so everything here intentionally works by class name and KVC
/// rather than by importing concrete types. The technique is the same one used
/// by `orchetect/MenuBarExtraAccess` and is package-agnostic.
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

    /// `NSApp` is a lazily-populated implicitly-unwrapped optional. SwiftUI may
    /// call into this code during `App.init`, before `NSApplication` exists, so
    /// every lookup has to tolerate a nil app instead of trapping.
    private static var windows: [NSWindow] {
        guard NSApp != nil else { return [] }
        return NSApp.windows
    }

    /// Finds the canonical status item with the given accessibility title.
    static func findStatusItem(accessibilityTitle: String) -> NSStatusItem? {
        let concreteName = concreteStatusItemClassName

        return windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap(extractStatusItem(from:))
            // Multi-display setups with "Displays have separate Spaces" enabled produce
            // one NSStatusBarWindow per display; the inactive ones return an
            // `NSStatusItemReplicant` (a subclass of NSStatusItem). Skip replicants —
            // we only want the canonical item that owns the real button.
            .filter { $0.className == concreteName }
            .first { $0.button?.accessibilityTitle() == accessibilityTitle }
    }

    /// Locates the popup panel created by `FluidMenuBarExtraWindow`. The concrete
    /// type isn't public, so match by runtime class name.
    static func findPanel() -> NSPanel? {
        windows.first { $0.className.contains("FluidMenuBarExtraWindow") } as? NSPanel
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
