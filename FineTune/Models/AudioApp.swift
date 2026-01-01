// FineTune/Models/AudioApp.swift
import AppKit
import AudioToolbox

struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let objectID: AudioObjectID
    let name: String
    let icon: NSImage
    let bundleID: String?

    var persistenceIdentifier: String {
        bundleID ?? "name:\(name)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}
