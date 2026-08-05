// FineTuneTests/URLHandlerGroupTests.swift
import Testing
import Foundation
import AppKit
@testable import FineTune

@MainActor
private final class MockURLHandlerEngine: URLHandlerEngine {
    var apps: [AudioApp] = []
    let settingsManager: SettingsManager

    var groupVolumes: [UUID: Float] = [:]
    var groupMutes: [UUID: Bool] = [:]
    var groupDevices: [UUID: String?] = [:]
    var appVolumes: [String: Float] = [:]
    var appMutes: [String: Bool] = [:]

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        appVolumes[app.persistenceIdentifier] = volume
    }

    func getVolume(for app: AudioApp) -> Float {
        appVolumes[app.persistenceIdentifier] ?? 1.0
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        appMutes[app.persistenceIdentifier] = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        appMutes[app.persistenceIdentifier] ?? false
    }

    func setDevice(for app: AudioApp, deviceUID: String?) {}

    func setVolumeForInactive(identifier: String, to volume: Float) {
        appVolumes[identifier] = volume
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        appMutes[identifier] = muted
    }

    func getMuteForInactive(identifier: String) -> Bool {
        appMutes[identifier] ?? false
    }

    func setGroupVolume(id: UUID, to volume: Float) {
        groupVolumes[id] = volume
        settingsManager.setGroupVolume(id: id, to: volume)
    }

    func setGroupMute(id: UUID, to muted: Bool) {
        groupMutes[id] = muted
        settingsManager.setGroupMute(id: id, to: muted)
    }

    func toggleGroupMute(id: UUID) {
        let current = settingsManager.appGroup(id: id)?.muted ?? false
        setGroupMute(id: id, to: !current)
    }

    func setGroupDevice(id: UUID, deviceUID: String?) {
        groupDevices.updateValue(deviceUID, forKey: id)
        settingsManager.setGroupDeviceRouting(id: id, deviceUID: deviceUID)
    }
}

@Suite("URLHandler — app groups")
@MainActor
struct URLHandlerGroupTests {
    private func makeHarness(groupName: String = "Voice") -> (URLHandler, MockURLHandlerEngine, UUID) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let group = settings.createAppGroup(name: groupName)
        settings.addAppToGroup(
            groupID: group.id,
            member: AppGroupMemberInfo(
                persistenceIdentifier: "com.hnc.Discord",
                displayName: "Discord",
                bundleID: "com.hnc.Discord"
            )
        )
        let engine = MockURLHandlerEngine(settingsManager: settings)
        return (URLHandler(audioEngine: engine), engine, group.id)
    }

    @Test("set-volumes by group name fans out through setGroupVolume")
    func setGroupVolumeByName() {
        let (handler, engine, groupID) = makeHarness()
        handler.handleURL(URL(string: "finetune://set-volumes?group=Voice&volume=40")!)
        #expect(abs((engine.groupVolumes[groupID] ?? -1) - 0.4) < 0.001)
        #expect(engine.settingsManager.appGroup(id: groupID)?.volume == 0.4)
    }

    @Test("set-volumes matches group names case-insensitively")
    func setGroupVolumeCaseInsensitive() {
        let (handler, engine, groupID) = makeHarness()
        handler.handleURL(URL(string: "finetune://set-volumes?group=voice&volume=25")!)
        #expect(abs((engine.groupVolumes[groupID] ?? -1) - 0.25) < 0.001)
    }

    @Test("toggle-mute toggles group mute")
    func toggleGroupMute() {
        let (handler, engine, groupID) = makeHarness()
        #expect(engine.settingsManager.appGroup(id: groupID)?.muted == false)
        handler.handleURL(URL(string: "finetune://toggle-mute?group=Voice")!)
        #expect(engine.groupMutes[groupID] == true)
        handler.handleURL(URL(string: "finetune://toggle-mute?group=Voice")!)
        #expect(engine.groupMutes[groupID] == false)
    }

    @Test("step-volume up raises group volume")
    func stepGroupVolumeUp() {
        let (handler, engine, groupID) = makeHarness()
        handler.handleURL(URL(string: "finetune://set-volumes?group=Voice&volume=50")!)
        handler.handleURL(URL(string: "finetune://step-volume?group=Voice&direction=up")!)
        let volume = engine.groupVolumes[groupID] ?? 0
        #expect(volume > 0.5)
    }

    @Test("set-device default follows system for groups")
    func setGroupDeviceDefault() {
        let (handler, engine, groupID) = makeHarness()
        handler.handleURL(URL(string: "finetune://set-device?group=Voice&device=BuiltInSpeakerDevice")!)
        #expect(engine.settingsManager.appGroup(id: groupID)?.followsDefault == false)

        handler.handleURL(URL(string: "finetune://set-device?group=Voice&device=default")!)
        #expect(engine.groupDevices[groupID] == .some(nil))
        #expect(engine.settingsManager.appGroup(id: groupID)?.followsDefault == true)
    }

    @Test("reset group restores 100% unmuted")
    func resetGroup() {
        let (handler, engine, groupID) = makeHarness()
        handler.handleURL(URL(string: "finetune://set-volumes?group=Voice&volume=20")!)
        handler.handleURL(URL(string: "finetune://set-mute?group=Voice&muted=true")!)
        handler.handleURL(URL(string: "finetune://reset?group=Voice")!)
        #expect(engine.groupVolumes[groupID] == 1.0)
        #expect(engine.groupMutes[groupID] == false)
    }

    @Test("unknown group name is a no-op")
    func unknownGroupNoOp() {
        let (handler, engine, groupID) = makeHarness()
        handler.handleURL(URL(string: "finetune://set-volumes?group=Missing&volume=10")!)
        #expect(engine.groupVolumes[groupID] == nil)
    }
}
