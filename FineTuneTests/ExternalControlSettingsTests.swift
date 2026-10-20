import XCTest
@testable import FineTune

nonisolated final class ExternalControlSettingsTests: XCTestCase {
    func testDefaultOffAndBackwardCompatibleDecode() throws {
        XCTAssertFalse(AppSettings().externalControlEnabled)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).externalControlEnabled)
        let enabled = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"externalControlEnabled":true}"#.utf8))
        XCTAssertTrue(enabled.externalControlEnabled)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(enabled)), enabled)
    }
}
