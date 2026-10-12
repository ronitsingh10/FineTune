import Foundation
import Observation

/// Full snapshots are used for events, so a missed revision can be replaced safely.
@MainActor
final class AutomationStateBroker {
    let service: AutomationService
    private var continuations: [UUID: AsyncStream<AutomationValue>.Continuation] = [:]
    private var lastRevision: Double = -1
    private var timer: Task<Void, Never>?
    private var coalescer: Task<Void, Never>?
    init(service: AutomationService) { self.service = service }
    func subscribe() -> AsyncStream<AutomationValue> {
        let id = UUID()
        let stream = AsyncStream<AutomationValue>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(event("state.snapshot"))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
        if timer == nil {
            trackChanges()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    guard let self else { break }
                    if self.continuations.isEmpty {
                        self.timer = nil
                        break
                    }
                    self.reconcile()
                }
            }
        }
        return stream
    }
    private func event(_ name: String) -> AutomationValue {
        var snapshot = service.snapshot().object ?? [:]
        snapshot["apiVersion"] = .number(1)
        snapshot["event"] = .string(name)
        return .object(snapshot)
    }
    func reconcile() {
        let value = event("state.changed")
        let revision = value.object?["revision"]?.number ?? 0
        guard revision != lastRevision else { return }
        lastRevision = revision
        for continuation in continuations.values { continuation.yield(value) }
    }
    private func trackChanges() {
        guard !continuations.isEmpty else { return }
        withObservationTracking {
            _ = service.snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleReconcile() }
        }
    }
    private func scheduleReconcile() {
        guard coalescer == nil else { return }
        coalescer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self else { return }
            self.coalescer = nil
            self.reconcile()
            self.trackChanges()
        }
    }
    func stop() {
        timer?.cancel()
        timer = nil
        coalescer?.cancel()
        coalescer = nil
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }
}
