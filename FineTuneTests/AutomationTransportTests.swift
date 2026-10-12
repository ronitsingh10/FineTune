import Foundation
import Testing

@testable import FineTune

@Suite("Automation transport")
struct AutomationTransportTests {
    @Test func fragmentedFramesAndUTF8Validation() throws {
        var decoder = AutomationFrameDecoder()
        #expect(try decoder.append(Data("{\"apiVersion\":1,".utf8)).isEmpty)
        let rest = Data(
            "\"id\":\"1\",\"method\":\"state.get\",\"params\":{}}\n{\"apiVersion\":1,\"id\":\"2\",\"method\":\"state.get\",\"params\":{}}\n"
                .utf8)
        #expect(try decoder.append(rest).map(\.id) == ["1", "2"])
        #expect(throws: (any Error).self) { try decoder.append(Data([0xff, 10])) }
    }
    @Test func frameLimitRejectsUnterminatedFlood() {
        var decoder = AutomationFrameDecoder()
        #expect(throws: (any Error).self) { try decoder.append(Data(repeating: 65, count: 1_048_577)) }
    }
    @Test func discoveryRefusesSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Automation")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { try AutomationDiscovery.prepareDirectory(link) }
    }
}
