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
/// A generation counter prevents stale timeouts from consuming live counters:
/// each increment and consume bumps the generation, so a timeout that fires
/// after the echo was already consumed will see a generation mismatch and no-op.
@MainActor
final class EchoTracker {

    /// Fired when a timeout expires without the echo being consumed.
    /// The caller should re-evaluate the default device.
    var onTimeout: ((_ uid: String) -> Void)?

    private let label: String
    private let logger: Logger
    private let timeoutDuration: TimeInterval

    /// Per-UID reference count of expected echoes.
    private var counters: [String: Int] = [:]

    /// Per-UID generation, bumped on every increment and consume.
    /// Timeout tasks capture the generation at creation; if it no longer
    /// matches when the timeout fires, the task is stale and no-ops.
    private var generations: [String: Int] = [:]

    init(label: String, timeoutDuration: TimeInterval = 2.0,
         logger: Logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "EchoTracker")) {
        self.label = label
        self.timeoutDuration = timeoutDuration
        self.logger = logger
    }

    /// Record that we're about to programmatically change the default device.
    /// Must be called *after* confirming the HAL call succeeded.
    func increment(_ uid: String) {
        counters[uid, default: 0] += 1
        generations[uid, default: 0] += 1
        let generation = generations[uid]!
        let duration = timeoutDuration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            guard self.generations[uid] == generation else { return }
            guard let count = self.counters[uid], count > 0 else { return }
            self.counters[uid] = count - 1
            if count == 1 { self.counters.removeValue(forKey: uid) }
            self.logger.warning("\(self.label) echo for \(uid) timed out")
            self.onTimeout?(uid)
        }
    }

    /// Try to consume one pending echo for this UID.
    /// Returns `true` if an echo was pending (caller should ignore the callback).
    func consume(_ uid: String) -> Bool {
        guard let count = counters[uid], count > 0 else { return false }
        counters[uid] = count - 1
        if count == 1 { counters.removeValue(forKey: uid) }
        // Bump generation so the corresponding timeout no-ops
        generations[uid, default: 0] += 1
        return true
    }

    /// Whether any echo is pending for any device.
    /// Used to skip interim routing when an override is in flight.
    var hasPending: Bool {
        counters.values.contains { $0 > 0 }
    }
}
