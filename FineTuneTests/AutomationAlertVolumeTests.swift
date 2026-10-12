import Foundation
import Testing

@testable import FineTune

@Suite("Alert volume confirmation")
struct AutomationAlertVolumeTests {
    @Test func rejectsReadbackMismatch() {
        #expect(throws: AutomationError.self) {
            try AlertVolumeAutomation.decode(Data("60\n".utf8), requested: 30)
        }
        #expect(throws: AutomationError.self) {
            try AlertVolumeAutomation.decode(Data("not a volume\n".utf8), requested: 30)
        }
    }
    @Test func acceptsMatchingReadback() throws {
        #expect(try AlertVolumeAutomation.decode(Data("30\n".utf8), requested: 30) == 0.3)
    }
}
