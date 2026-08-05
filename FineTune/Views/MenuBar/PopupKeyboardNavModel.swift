// FineTune/Views/MenuBar/PopupKeyboardNavModel.swift
import Foundation

@MainActor
@Observable
final class PopupKeyboardNavModel {
    enum RowID: Hashable {
        case device(uid: String)
        case app(persistenceID: String)
        case group(id: UUID)
    }

    private(set) var orderedRowIDs: [RowID] = []

    func syncOrder(
        activeDevices: [AudioDevice],
        itemRowIDs: [RowID],
        isEditingPriority: Bool
    ) {
        guard !isEditingPriority else {
            orderedRowIDs = []
            return
        }
        var next: [RowID] = []
        next.reserveCapacity(activeDevices.count + itemRowIDs.count)
        for device in activeDevices {
            next.append(.device(uid: device.uid))
        }
        next.append(contentsOf: itemRowIDs)
        orderedRowIDs = next
    }

    /// Convenience for tests and call sites that only have ungrouped app IDs.
    func syncOrder(
        activeDevices: [AudioDevice],
        appPersistenceIDs: [String],
        isEditingPriority: Bool
    ) {
        syncOrder(
            activeDevices: activeDevices,
            itemRowIDs: appPersistenceIDs.map { .app(persistenceID: $0) },
            isEditingPriority: isEditingPriority
        )
    }

    func next(after current: RowID?) -> RowID? {
        guard !orderedRowIDs.isEmpty else { return nil }
        guard let current else { return orderedRowIDs.first }
        guard let index = orderedRowIDs.firstIndex(of: current) else {
            return orderedRowIDs.first
        }
        let nextIndex = index + 1
        return nextIndex < orderedRowIDs.count ? orderedRowIDs[nextIndex] : nil
    }

    func previous(before current: RowID?) -> RowID? {
        guard !orderedRowIDs.isEmpty else { return nil }
        guard let current else { return nil }
        guard let index = orderedRowIDs.firstIndex(of: current) else {
            return nil
        }
        return index > 0 ? orderedRowIDs[index - 1] : nil
    }

    func defaultFocus(defaultOutputUID: String?) -> RowID? {
        guard !orderedRowIDs.isEmpty else { return nil }
        if let uid = defaultOutputUID {
            let candidate = RowID.device(uid: uid)
            if orderedRowIDs.contains(candidate) {
                return candidate
            }
        }
        return orderedRowIDs.first
    }
}
