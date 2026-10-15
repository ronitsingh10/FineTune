// FineTuneTests/AppInstanceTests.swift
import AppKit
import Testing
@testable import FineTune

@Suite("AppInstance")
struct AppInstanceTests {
    private let home = "/Users/tester"

    @Test("Normal launch has no instance")
    func noFlag() {
        #expect(AppInstance.from(arguments: ["/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"], homeDirectory: home) == nil)
        #expect(AppInstance.from(arguments: [], homeDirectory: home) == nil)
    }

    @Test("Chromium --user-data-dir, both = and separate-argument forms")
    func chromium() {
        let expected = AppInstance(key: "~/Library/Application Support/BraveSecond", label: "BraveSecond")
        #expect(AppInstance.from(arguments: ["brave", "--user-data-dir=/Users/tester/Library/Application Support/BraveSecond"], homeDirectory: home) == expected)
        #expect(AppInstance.from(arguments: ["brave", "--user-data-dir", "/Users/tester/Library/Application Support/BraveSecond/"], homeDirectory: home) == expected)
    }

    @Test("Paths outside home stay absolute; root and empty paths are ignored")
    func pathEdgeCases() {
        #expect(AppInstance.from(arguments: ["brave", "--user-data-dir=/tmp/b2"], homeDirectory: home)
            == AppInstance(key: "/tmp/b2", label: "b2"))
        #expect(AppInstance.from(arguments: ["brave", "--user-data-dir=/"], homeDirectory: home) == nil)
        #expect(AppInstance.from(arguments: ["brave", "--user-data-dir="], homeDirectory: home) == nil)
    }

    @Test("Firefox -profile path and -P name")
    func firefox() {
        #expect(AppInstance.from(arguments: ["firefox", "-profile", "/Users/tester/ff/work"], homeDirectory: home)
            == AppInstance(key: "~/ff/work", label: "work"))
        #expect(AppInstance.from(arguments: ["firefox", "-P", "Music"], homeDirectory: home)
            == AppInstance(key: "profile:Music", label: "Music"))
    }

    @Test("Flag-like values that merely share a prefix are not matched")
    func prefixOnly() {
        #expect(AppInstance.from(arguments: ["brave", "--user-data-directory=/x"], homeDirectory: home) == nil)
    }

    @Test("KERN_PROCARGS2 buffer parsing")
    func procArgsParsing() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
        buffer += Array("/bin/exec".utf8) + [0, 0, 0]
        buffer += Array("brave".utf8) + [0]
        buffer += Array("--user-data-dir=/tmp/b2".utf8) + [0]
        buffer += Array("PATH=/usr/bin".utf8) + [0]  // environment follows argv
        #expect(AppInstance.parseProcArgs(buffer) == ["brave", "--user-data-dir=/tmp/b2"])
        #expect(AppInstance.parseProcArgs([0, 0]) == nil)
    }

    @Test("Reads this test process's own arguments")
    func liveProcess() {
        let args = AppInstance.processArguments(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(args?.isEmpty == false)
    }

    @Test("Persistence identifier is unchanged without an instance and suffixed with one")
    func persistenceIdentifier() {
        let plain = AudioApp(id: 1, processObjectIDs: [], name: "Brave Browser", icon: NSImage(), bundleID: "com.brave.Browser")
        #expect(plain.persistenceIdentifier == "com.brave.Browser")

        let second = AudioApp(
            id: 2, processObjectIDs: [], name: "Brave Browser (BraveSecond)", icon: NSImage(),
            bundleID: "com.brave.Browser",
            instance: AppInstance(key: "~/BraveSecond", label: "BraveSecond")
        )
        #expect(second.persistenceIdentifier == "com.brave.Browser@~/BraveSecond")
        #expect(second.persistenceIdentifier != plain.persistenceIdentifier)
    }
}
