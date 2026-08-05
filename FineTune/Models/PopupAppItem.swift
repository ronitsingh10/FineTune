// FineTune/Models/PopupAppItem.swift
import Foundation

/// Top-level items shown in the menu bar Apps section: either a group
/// (with nested live/inactive members) or an ungrouped displayable app.
enum PopupAppItem: Identifiable {
    case group(AppGroup, liveMembers: [AudioApp], inactiveMembers: [AppGroupMemberInfo])
    case app(DisplayableApp)

    var id: String {
        switch self {
        case .group(let group, _, _):
            return "group:\(group.id.uuidString)"
        case .app(let displayable):
            return displayable.id
        }
    }

    var groupID: UUID? {
        if case .group(let group, _, _) = self {
            return group.id
        }
        return nil
    }
}
