// FineTune/Models/AppGroup.swift
import Foundation

/// Metadata for an app that belongs to an audio group.
nonisolated struct AppGroupMemberInfo: Codable, Equatable, Identifiable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?

    var id: String { persistenceIdentifier }
}

/// A named collection of apps that share absolute volume, mute, EQ, boost, and routing.
nonisolated struct AppGroup: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var members: [AppGroupMemberInfo]
    var volume: Float
    var muted: Bool
    var eqSettings: EQSettings
    var boost: BoostLevel
    /// When true, members follow the system default output (deviceUID ignored).
    var followsDefault: Bool
    /// Explicit single-device UID when `followsDefault` is false and mode is `.single`.
    var deviceUID: String?
    var deviceSelectionMode: DeviceSelectionMode
    var selectedDeviceUIDs: [String]
    var isCollapsed: Bool

    var memberIdentifiers: [String] {
        members.map(\.persistenceIdentifier)
    }

    init(
        id: UUID = UUID(),
        name: String,
        members: [AppGroupMemberInfo] = [],
        volume: Float = 1.0,
        muted: Bool = false,
        eqSettings: EQSettings = .flat,
        boost: BoostLevel = .x1,
        followsDefault: Bool = true,
        deviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        selectedDeviceUIDs: [String] = [],
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.volume = volume
        self.muted = muted
        self.eqSettings = eqSettings
        self.boost = boost
        self.followsDefault = followsDefault
        self.deviceUID = deviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isCollapsed = isCollapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        members = try c.decodeIfPresent([AppGroupMemberInfo].self, forKey: .members) ?? []
        let decodedVolume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        volume = decodedVolume.isFinite ? max(0, min(1, decodedVolume)) : 1.0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        eqSettings = try c.decodeIfPresent(EQSettings.self, forKey: .eqSettings) ?? .flat
        boost = try c.decodeIfPresent(BoostLevel.self, forKey: .boost) ?? .x1
        followsDefault = try c.decodeIfPresent(Bool.self, forKey: .followsDefault) ?? true
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        deviceSelectionMode = try c.decodeIfPresent(DeviceSelectionMode.self, forKey: .deviceSelectionMode) ?? .single
        selectedDeviceUIDs = try c.decodeIfPresent([String].self, forKey: .selectedDeviceUIDs) ?? []
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}
