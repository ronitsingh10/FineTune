// FineTune/Audio/Permission/AccessibilityPermission.swift
import AppKit
import ApplicationServices

@Observable
@MainActor
final class AccessibilityPermission {
    private(set) var isGranted: Bool = false

    init() {
        check()
        registerForActivation()
    }

    func check() {
        isGranted = AXIsProcessTrusted()
    }

    func requestWithPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isGranted = AXIsProcessTrustedWithOptions(options)
    }

    private func registerForActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.check()
            }
        }
    }
}
