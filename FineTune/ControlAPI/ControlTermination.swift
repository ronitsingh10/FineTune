import Foundation

@MainActor
final class ControlTermination {
    private var started = false
    private var reply: (@MainActor () -> Void)?
    private var fallback: Task<Void, Never>?
    private let schedule: (@escaping @MainActor () -> Void) -> Task<Void, Never>

    init(schedule: @escaping (@escaping @MainActor () -> Void) -> Task<Void, Never> = { action in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            action()
        }
    }) {
        self.schedule = schedule
    }

    func begin(stop: (@escaping @Sendable () -> Void) -> Void, reply: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        self.reply = reply
        fallback = schedule { [weak self] in self?.finish() }
        stop { [weak self] in
            DispatchQueue.main.async { self?.finish() }
        }
    }

    private func finish() {
        guard let reply else { return }
        self.reply = nil
        fallback?.cancel()
        fallback = nil
        reply()
    }
}
