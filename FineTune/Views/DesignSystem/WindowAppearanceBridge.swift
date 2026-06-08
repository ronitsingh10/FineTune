// FineTune/Views/DesignSystem/WindowAppearanceBridge.swift
import SwiftUI
import AppKit

/// Bridges a SwiftUI body's resolved `NSAppearance?` to its host `NSWindow`'s
/// `.appearance` property. Insert as an invisible (`.frame(width: 0, height: 0)`)
/// background or overlay in views that own a window's appearance.
///
/// Why a bridge: `.preferredColorScheme(...)` only changes SwiftUI's color
/// resolution. The underlying NSWindow / NSPanel keeps its own NSAppearance,
/// which is what governs `NSVisualEffectView` material rendering. Without this
/// bridge, applying `.preferredColorScheme(.light)` would change SwiftUI Colors
/// but leave a `.regularMaterial` background rendering as dark glass.
struct WindowAppearanceBridge: NSViewRepresentable {
    /// The desired `NSAppearance` to apply to the host window. `nil` means
    /// "inherit from the application", which is correct for the System mode.
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> WindowAppearanceTrackerView {
        WindowAppearanceTrackerView()
    }

    func updateNSView(_ nsView: WindowAppearanceTrackerView, context: Context) {
        nsView.desiredAppearance = appearance
    }
}

/// Private NSView subclass that retains the desired appearance and re-applies
/// it on `viewDidMoveToWindow`. This catches the case where the initial
/// `updateNSView` runs before SwiftUI has parented the hosting view into a
/// window — when the window finally arrives, we still apply the correct value.
///
/// When `desiredAppearance` is `nil` (System mode) we apply `NSApp.effectiveAppearance`
/// instead of `nil`. Setting `NSWindow.appearance = nil` leaves persistent windows
/// resolving `NSColor` against the previously-locked appearance until something
/// kicks the window (key/main change, certain redraws), which produces a stale
/// "labels look faded" frame after Light→System until refocus. KVO on
/// `NSApp.effectiveAppearance` re-mirrors the live system value while we're in
/// System mode so the window's appearance is always concrete.
final class WindowAppearanceTrackerView: NSView {
    var desiredAppearance: NSAppearance? {
        didSet { applyAppearance() }
    }
    private var appearanceObservation: NSKeyValueObservation?

    private func applyAppearance() {
        window?.appearance = desiredAppearance ?? NSApp.effectiveAppearance
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.desiredAppearance == nil else { return }
                self.applyAppearance()
            }
        }
    }
}

// MARK: - Environment

/// Environment key carrying the app's resolved `AppearancePreference` down to
/// descendant views so child popovers / panels can mirror the preference to
/// their own `NSPanel.appearance` and `.preferredColorScheme(...)`.
///
/// Set at popup / HUD roots (`MenuBarPopupView`, `HUDWindowController`) so
/// nested pickers (`PopoverHost` consumers) can wire it through without each
/// intermediate view threading a binding to `appSettings`.
private struct AppearancePreferenceKey: EnvironmentKey {
    static let defaultValue: AppearancePreference = .system
}

extension EnvironmentValues {
    var appearancePreference: AppearancePreference {
        get { self[AppearancePreferenceKey.self] }
        set { self[AppearancePreferenceKey.self] = newValue }
    }
}
