// FineTuneTests/AudioProcessMonitorIdentityTests.swift
import Testing
import Foundation
import AppKit
@testable import FineTune

@Suite("AudioProcessMonitor identity for bare executables")
struct AudioProcessMonitorIdentityTests {
    @Test("Empty bundle ID is treated as missing")
    func emptyBundleIDIsNil() -> Void {
        #expect(AudioProcessMonitor.nonEmpty("") == nil)
        #expect(AudioProcessMonitor.nonEmpty(nil) == nil)
        #expect(AudioProcessMonitor.nonEmpty("com.example.app") == "com.example.app")
    }

    @Test("Bare executable with empty bundle ID is named after its executable")
    func bareExecutableUsesExecutableName() -> Void {
        let name: String = AudioProcessMonitor.displayName(
            resolvedAppName: nil,
            coreAudioBundleID: AudioProcessMonitor.nonEmpty(""),
            directAppName: nil,
            executablePath: "/Users/me/game/build/pokeheartgold"
        )
        #expect(name == "pokeheartgold")
    }

    @Test("Bare executable keeps a distinct, non-empty persistence key")
    func bareExecutablePersistenceKey() -> Void {
        let name: String = AudioProcessMonitor.displayName(
            resolvedAppName: nil,
            coreAudioBundleID: nil,
            directAppName: "mygame",
            executablePath: nil
        )
        let app = AudioApp(id: 1, processObjectIDs: [1], name: name, icon: NSImage(), bundleID: AudioProcessMonitor.nonEmpty(""))
        #expect(app.persistenceIdentifier == "name:mygame")
    }

    @Test("Resolved app name wins over fallbacks")
    func resolvedAppNameWins() -> Void {
        let name: String = AudioProcessMonitor.displayName(
            resolvedAppName: "Safari",
            coreAudioBundleID: "com.apple.WebKit.GPU",
            directAppName: "helper",
            executablePath: "/x/helper"
        )
        #expect(name == "Safari")
    }

    @Test("Falls back to Unknown when nothing identifies the process")
    func unknownFallback() -> Void {
        let name: String = AudioProcessMonitor.displayName(
            resolvedAppName: "",
            coreAudioBundleID: nil,
            directAppName: "",
            executablePath: nil
        )
        #expect(name == "Unknown")
    }
}
