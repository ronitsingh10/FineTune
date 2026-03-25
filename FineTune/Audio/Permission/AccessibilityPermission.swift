// FineTune/Audio/Permission/AccessibilityPermission.swift
import AppKit
import ApplicationServices

@Observable
@MainActor
final class AccessibilityPermission {
    private(set) var isGranted: Bool = false
    private var activationObserver: NSObjectProtocol?

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
        activationObserver = NotificationCenter.default.addObserver(
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

    deinit {
        MainActor.assumeIsolated {
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
            }
        }
    }
}
