// FineTune/Shortcuts/TargetAppResolver.swift
import AppKit
import Foundation

@MainActor
protocol TargetAppResolving: AnyObject {
    func resolveTargetBundleID(audibleCandidates: [String]) -> String?
}

/// Activation notifications must be observed on `NSWorkspace.shared.notificationCenter`,
/// not `NotificationCenter.default`. Registering on the default center is a silent
/// no-op (`AppKit/NSWorkspace.h`).
@MainActor
@Observable
final class TargetAppResolver: TargetAppResolving {
    private static let systemDaemonBlocklist: Set<String> = [
        "com.apple.systemsoundserverd",
        "com.apple.coreaudiod",
    ]

    private let ownBundleID: String
    private let frontmostBundleIDProvider: @MainActor () -> String?
    private var lastNonFineTuneFrontmostBundleID: String?
    private var lastTargetedBundleID: String?
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
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.handleActivation(bundleID: bundleID)
            }
        }
    }

    func handleActivation(bundleID: String?) {
        guard let bundleID, bundleID != ownBundleID else { return }
        lastNonFineTuneFrontmostBundleID = bundleID
    }

    func resolveTargetBundleID(audibleCandidates: [String]) -> String? {
        let filtered = audibleCandidates.filter {
            $0 != ownBundleID && !Self.systemDaemonBlocklist.contains($0)
        }

        guard !filtered.isEmpty else {
            return resolveFrontmostNonFineTune()
        }

        if let frontmost = frontmostBundleIDProvider(),
           frontmost != ownBundleID,
           filtered.contains(frontmost) {
            lastTargetedBundleID = frontmost
            return frontmost
        }

        if let last = lastTargetedBundleID, filtered.contains(last) {
            return last
        }

        let target = filtered.first
        lastTargetedBundleID = target
        return target
    }

    private func resolveFrontmostNonFineTune() -> String? {
        let frontmost = frontmostBundleIDProvider()
        if let frontmost, frontmost != ownBundleID {
            return frontmost
        }
        return lastNonFineTuneFrontmostBundleID
    }
}
