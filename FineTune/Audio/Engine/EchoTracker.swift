import Foundation
import os

/// Reference-counted echo suppression for CoreAudio default-device changes.
///
/// When we programmatically set the system default device, CoreAudio fires a
/// property-changed callback with the same UID. Without suppression, we'd
/// interpret our own change as an external event and re-route apps.
///
/// The tracker is reference-counted (not boolean) so rapid reconnects of the
/// same device increment independently, and each echo is consumed separately.
///
/// Each increment creates a unique token stored in a per-UID set. Timeouts
/// check their own token; consume removes one token. This ensures timeouts
/// are invalidated individually, not en masse.
@MainActor
final class EchoTracker {

    /// Fired when a timeout expires without the echo being consumed.
    /// The caller should re-evaluate the default device.
    var onTimeout: ((_ uid: String) -> Void)?

    private let label: String
    private let logger: Logger
    private let timeoutDuration: TimeInterval

    /// Per-UID set of active timeout tokens. Each increment adds one;
    /// each consume or successful timeout removes one.
    private var activeTimeouts: [String: Set<Int>] = [:]
    private var nextToken: Int = 0

    init(label: String, timeoutDuration: TimeInterval = 2.0,
         logger: Logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "EchoTracker")) {
        self.label = label
        self.timeoutDuration = timeoutDuration
        self.logger = logger
    }

    /// Record that we're about to programmatically change the default device.
    /// Must be called *after* confirming the HAL call succeeded.
    func increment(_ uid: String) {
        let token = nextToken
        nextToken += 1
        activeTimeouts[uid, default: []].insert(token)
        let duration = timeoutDuration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            guard self.activeTimeouts[uid]?.remove(token) != nil else { return }
            if self.activeTimeouts[uid]?.isEmpty == true {
                self.activeTimeouts.removeValue(forKey: uid)
            }
            self.logger.warning("\(self.label) echo for \(uid) timed out")
            self.onTimeout?(uid)
        }
    }

    /// Try to consume one pending echo for this UID.
    /// Returns `true` if an echo was pending (caller should ignore the callback).
    func consume(_ uid: String) -> Bool {
        guard let token = activeTimeouts[uid]?.min() else { return false }
        activeTimeouts[uid]?.remove(token)
        if activeTimeouts[uid]?.isEmpty == true {
            activeTimeouts.removeValue(forKey: uid)
        }
        return true
    }

    /// Discard pending echoes and invalidate their timeout callbacks.
    func reset() {
        activeTimeouts.removeAll()
    }

    /// Whether any echo is pending for any device.
    /// Used to skip interim routing when an override is in flight.
    var hasPending: Bool {
        !activeTimeouts.isEmpty
    }
}
