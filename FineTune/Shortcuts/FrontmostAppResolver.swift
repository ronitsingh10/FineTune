// FineTune/Shortcuts/FrontmostAppResolver.swift
import AppKit
import Foundation

/// Activation notifications must be observed on `NSWorkspace.shared.notificationCenter`,
/// not `NotificationCenter.default`. Registering on the default center is a silent
/// no-op (`AppKit/NSWorkspace.h`).
@MainActor
@Observable
final class FrontmostAppResolver {
    private let ownBundleID: String
    private let frontmostBundleIDProvider: @MainActor () -> String?
    private var lastNonFineTuneFrontmostBundleID: String?

    private var observer: NSObjectProtocol?

    init(
        ownBundleID: String,
        frontmostBundleIDProvider: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.ownBundleID = ownBundleID
        self.frontmostBundleIDProvider = frontmostBundleIDProvider
    }

    /// Idempotent.
    func start() {
        guard observer == nil else { return }
        let nc = NSWorkspace.shared.notificationCenter
        observer = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.handleActivation(bundleID: app?.bundleIdentifier)
            }
        }
    }

    func handleActivation(bundleID: String?) {
        guard let bundleID, bundleID != ownBundleID else { return }
        lastNonFineTuneFrontmostBundleID = bundleID
    }

    func resolveTargetBundleID() -> String? {
        let frontmost = frontmostBundleIDProvider()
        if let frontmost, frontmost != ownBundleID {
            return frontmost
        }
        return lastNonFineTuneFrontmostBundleID
    }
}
