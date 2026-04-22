// FineTune/Audio/Keys/AccessibilityPermissionService.swift
import AppKit
import ApplicationServices
import os

@MainActor
protocol AccessibilityTrustProviding: AnyObject {
    /// Authoritative, non-cached read.
    var isTrusted: Bool { get }
    /// Syncs cached state against the authoritative read.
    func refresh()
}

/// Tracks AX trust via `AXIsProcessTrusted()` plus the
/// `com.apple.accessibility.api` distributed notification (250ms debounce).
@Observable
@MainActor
final class AccessibilityPermissionService: AccessibilityTrustProviding {
    private(set) var isTrustedCached: Bool

    /// Invoked on the main actor whenever `isTrustedCached` flips. Global path —
    /// `.onChange` in a view is insufficient because the popup may not be mounted.
    var onTrustChanged: ((Bool) -> Void)?

    private var trustObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AccessibilityPermissionService")

    var refreshDidFinish: (() -> Void)?

    init() {
        self.isTrustedCached = AXIsProcessTrusted()
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func refresh() {
        let current = AXIsProcessTrusted()
        guard current != isTrustedCached else {
            refreshDidFinish?()
            return
        }
        isTrustedCached = current
        logger.info("Accessibility trust refreshed synchronously: \(current ? "granted" : "revoked")")
        onTrustChanged?(current)
        refreshDidFinish?()
    }

    /// Idempotent. Subscribes to `com.apple.accessibility.api`.
    func start() {
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleDebouncedRefresh()
            }
        }
    }

    /// Idempotent.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let observer = trustObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            trustObserver = nil
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            self.debounceTask = nil
        }
    }

    /// Prompts for AX access and registers the app in the Accessibility pane list
    /// as a side effect — the only supported pre-population path.
    @discardableResult
    func promptForTrust() -> Bool {
        // Get-rule CFString; `.takeRetainedValue()` would over-release a framework singleton.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Registers in the AX list and opens System Settings as a cross-version fallback.
    func requestAccess() {
        let trusted = promptForTrust()
        if !trusted {
            openSystemSettings()
        }
    }
}
