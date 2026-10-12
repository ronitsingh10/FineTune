import Foundation

@MainActor
final class AutomationOperationStore {
    struct Record {
        let created: Date
        var status: String
        var result: AutomationValue?
        var error: AutomationError?
    }
    private var records: [String: Record] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var resources: Set<String> = []
    func isBusy(_ resource: String) -> Bool { resources.contains(resource) }
    func start(resource: String, operation: @escaping @MainActor () async throws -> AutomationValue) throws
        -> String
    {
        prune()
        guard tasks.count < 256, !resources.contains(resource) else {
            throw AutomationError(.busy, "Operation capacity or resource is busy")
        }
        let id = UUID().uuidString
        resources.insert(resource)
        records[id] = .init(created: Date(), status: "pending")
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.tasks[id] = nil
                self.resources.remove(resource)
                self.prune()
            }
            do {
                let value = try await operation()
                self.records[id]?.result = value
                self.records[id]?.status = "completed"
            } catch let error as AutomationError {
                self.records[id]?.error = error
                self.records[id]?.status = "failed"
            } catch {
                self.records[id]?.error = .init(.internalError, "Async operation failed")
                self.records[id]?.status = "failed"
            }
        }
        return id
    }
    func wait(_ id: String) async throws -> AutomationValue {
        if let task = tasks[id] { await task.value }
        try Task.checkCancellation()
        return try get(id)
    }
    func get(_ id: String) throws -> AutomationValue {
        prune()
        guard let record = records[id] else {
            throw AutomationError(.notFound, "Operation is unavailable or expired")
        }
        var result: [String: AutomationValue] = [
            "operationId": .string(id), "status": .string(record.status),
        ]
        if let outcome = record.result { result["result"] = outcome }
        if let error = record.error { result["error"] = try .encode(error) }
        return .object(result)
    }
    func snapshot() -> AutomationValue {
        .array(
            records.keys.sorted().compactMap { id in
                records[id].map { .object(["operationId": .string(id), "status": .string($0.status)]) }
            })
    }
    func cancelAll() { for task in tasks.values { task.cancel() } }
    private func prune() {
        let completed = records.filter { tasks[$0.key] == nil }.sorted { $0.value.created > $1.value.created }
        for (index, pair) in completed.enumerated()
        where index >= 256 || Date().timeIntervalSince(pair.value.created) > 600 { records[pair.key] = nil }
    }
}
