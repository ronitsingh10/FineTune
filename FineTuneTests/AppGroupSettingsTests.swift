// FineTuneTests/AppGroupSettingsTests.swift
import Testing
import Foundation
@testable import FineTune

@Suite("AppGroup settings persistence")
@MainActor
struct AppGroupSettingsTests {
    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("Default settings version is 13 with empty appGroups")
    func defaultVersionHasEmptyGroups() {
        let settings = SettingsManager.Settings()
        #expect(settings.version == 13)
        #expect(settings.appGroups.isEmpty)
    }

    @Test("Old settings without appGroups decode with empty groups")
    func legacyDecodeEmptyGroups() throws {
        let json = """
        {"version": 12, "appVolumes": {"com.test.app": 0.5}}
        """
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
        #expect(decoded.appGroups.isEmpty)
        #expect(decoded.appVolumes["com.test.app"] == 0.5)
    }

    @Test("AppGroup round-trips through Settings JSON")
    func groupRoundTrip() throws {
        var original = SettingsManager.Settings()
        let group = AppGroup(
            name: "Voice Chat",
            members: [
                AppGroupMemberInfo(
                    persistenceIdentifier: "com.hnc.Discord",
                    displayName: "Discord",
                    bundleID: "com.hnc.Discord"
                ),
                AppGroupMemberInfo(
                    persistenceIdentifier: "com.tinyspeck.slackmacgap",
                    displayName: "Slack",
                    bundleID: "com.tinyspeck.slackmacgap"
                )
            ],
            volume: 0.5,
            muted: true,
            eqSettings: EQSettings(bandGains: Array(repeating: 3.0, count: 10), isEnabled: true)
        )
        original.appGroups = [group]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appGroups.count == 1)
        #expect(decoded.appGroups[0].name == "Voice Chat")
        #expect(decoded.appGroups[0].members.count == 2)
        #expect(decoded.appGroups[0].volume == 0.5)
        #expect(decoded.appGroups[0].muted == true)
        #expect(decoded.appGroups[0].eqSettings.bandGains == Array(repeating: Float(3.0), count: 10))
    }

    @Test("setGroupVolume fans out to all member appVolumes")
    func groupVolumeFanOut() {
        let manager = makeManager()
        let group = manager.createAppGroup(name: "Voice Chat")
        manager.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.discord",
                displayName: "Discord",
                bundleID: "com.discord"
            )
        )
        manager.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.slack",
                displayName: "Slack",
                bundleID: "com.slack"
            )
        )

        manager.setGroupVolume(id: group.id, to: 0.25)

        #expect(manager.appGroup(id: group.id)?.volume == 0.25)
        #expect(manager.getVolume(for: "com.discord") == 0.25)
        #expect(manager.getVolume(for: "com.slack") == 0.25)
    }

    @Test("setGroupEQSettings fans out to all members")
    func groupEQFanOut() {
        let manager = makeManager()
        let group = manager.createAppGroup(name: "Music")
        manager.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.spotify",
                displayName: "Spotify",
                bundleID: "com.spotify"
            )
        )
        let eq = EQSettings(bandGains: Array(repeating: -2.0, count: 10), isEnabled: true)
        manager.setGroupEQSettings(id: group.id, eq)

        #expect(manager.appGroup(id: group.id)?.eqSettings == eq)
        #expect(manager.getEQSettings(for: "com.spotify") == eq)
    }

    @Test("Adding a member applies current group volume and EQ")
    func addMemberAppliesGroupSettings() {
        let manager = makeManager()
        let group = manager.createAppGroup(name: "Voice Chat")
        manager.setGroupVolume(id: group.id, to: 0.4)
        let eq = EQSettings(bandGains: Array(repeating: 1.5, count: 10), isEnabled: true)
        manager.setGroupEQSettings(id: group.id, eq)

        manager.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.discord",
                displayName: "Discord",
                bundleID: "com.discord"
            )
        )

        #expect(manager.getVolume(for: "com.discord") == 0.4)
        #expect(manager.getEQSettings(for: "com.discord") == eq)
        #expect(manager.getMute(for: "com.discord") == false)
    }

    @Test("An app belongs to at most one group")
    func singleGroupMembership() {
        let manager = makeManager()
        let a = manager.createAppGroup(name: "A")
        let b = manager.createAppGroup(name: "B")
        let member = AppGroupMemberInfo(
            persistenceIdentifier: "com.discord",
            displayName: "Discord",
            bundleID: "com.discord"
        )
        manager.addAppToGroup(groupID: a.id, member: member)
        manager.addAppToGroup(groupID: b.id, member: member)

        #expect(manager.appGroup(id: a.id)?.members.isEmpty == true)
        #expect(manager.appGroup(id: b.id)?.memberIdentifiers == ["com.discord"])
        #expect(manager.group(containing: "com.discord")?.id == b.id)
    }

    @Test("Ignoring an app removes it from groups")
    func ignoreRemovesMembership() {
        let manager = makeManager()
        let group = manager.createAppGroup(name: "Voice Chat")
        manager.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.discord",
                displayName: "Discord",
                bundleID: "com.discord"
            )
        )
        manager.ignoreApp(
            "com.discord",
            info: IgnoredAppInfo(
                persistenceIdentifier: "com.discord",
                displayName: "Discord",
                bundleID: "com.discord"
            )
        )

        #expect(manager.appGroup(id: group.id)?.members.isEmpty == true)
        #expect(manager.group(containing: "com.discord") == nil)
        #expect(manager.isIgnored("com.discord"))
    }

    @Test("Prune keeps settings for grouped inactive members")
    func pruneKeepsGroupedMembers() {
        let manager = makeManager()
        let group = manager.createAppGroup(name: "Voice Chat")
        manager.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.discord",
                displayName: "Discord",
                bundleID: "com.discord"
            )
        )
        // Defaults would normally be pruned for inactive unpinned apps
        manager.setVolume(for: "com.discord", to: 1.0)
        manager.pruneStaleSettings(keeping: [])

        #expect(manager.getVolume(for: "com.discord") == 1.0)
        #expect(manager.appGroup(id: group.id)?.members.count == 1)
    }

    @Test("resetAllSettings clears appGroups")
    func resetClearsGroups() {
        let manager = makeManager()
        _ = manager.createAppGroup(name: "Voice Chat")
        manager.resetAllSettings()
        #expect(manager.appGroups.isEmpty)
    }

    @Test("groupedAppIdentifiers excludes ungrouped apps from the set")
    func groupedIdentifiersSet() {
        let manager = makeManager()
        let group = manager.createAppGroup(name: "Voice Chat")
        manager.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.discord",
                displayName: "Discord",
                bundleID: "com.discord"
            )
        )
        #expect(manager.groupedAppIdentifiers == Set(["com.discord"]))
    }
}

@Suite("PopupKeyboardNavModel — groups")
@MainActor
struct PopupKeyboardNavGroupTests {
    @Test("syncOrder includes group rows between devices and apps")
    func syncOrderWithGroups() {
        let model = PopupKeyboardNavModel()
        let groupID = UUID()
        let device = AudioDevice(id: 1, uid: "dev1", name: "Speakers", icon: nil, supportsAutoEQ: false)
        model.syncOrder(
            activeDevices: [device],
            itemRowIDs: [
                .group(id: groupID),
                .app(persistenceID: "com.spotify")
            ],
            isEditingPriority: false
        )
        #expect(model.orderedRowIDs == [
            .device(uid: "dev1"),
            .group(id: groupID),
            .app(persistenceID: "com.spotify")
        ])
        #expect(model.next(after: .device(uid: "dev1")) == .group(id: groupID))
        #expect(model.next(after: .group(id: groupID)) == .app(persistenceID: "com.spotify"))
    }
}
