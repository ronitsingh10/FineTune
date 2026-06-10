// FineTune/Views/DesignSystem/WindowTitleBridge.swift
import SwiftUI
import AppKit

/// Pins the host `NSWindow`'s title to a fixed string. Insert as an invisible
/// background in scenes whose title would otherwise be driven by SwiftUI
/// (notably `Settings { TabView { … } }`, where macOS rewrites the window
/// title from the selected tab's `.tabItem` label on every selection change).
///
/// Why KVO instead of just setting once: the macOS `Settings` scene re-asserts
/// the tab-derived title each time the user changes tabs, so a one-shot
/// assignment in `viewDidMoveToWindow` would be overwritten on the next switch.
struct WindowTitleBridge: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleTrackerView {
        WindowTitleTrackerView(desiredTitle: title)
    }

    func updateNSView(_ nsView: WindowTitleTrackerView, context: Context) {
        nsView.desiredTitle = title
    }
}

final class WindowTitleTrackerView: NSView {
    var desiredTitle: String {
        didSet {
            guard oldValue != desiredTitle else { return }
            applyAndObserve()
        }
    }

    private var observation: NSKeyValueObservation?

    init(desiredTitle: String) {
        self.desiredTitle = desiredTitle
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAndObserve()
    }

    deinit { observation?.invalidate() }

    private func applyAndObserve() {
        observation?.invalidate()
        observation = nil

        guard let window else { return }
        if window.title != desiredTitle {
            window.title = desiredTitle
        }
        observation = window.observe(\.title, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, window.title != self.desiredTitle else { return }
                window.title = self.desiredTitle
            }
        }
    }
}
