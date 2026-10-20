import XCTest
@testable import FineTune

nonisolated final class ControlProtocolTests: XCTestCase {
    func testJSONRoundTripPreservesTypesAndNulls() throws {
        let value = ControlJSON.object([
            "null": .null, "bool": .bool(true), "number": .number(0.5),
            "array": .array([.string("日本語"), .number(12)])
        ])
        XCTAssertEqual(try JSONDecoder().decode(ControlJSON.self, from: JSONEncoder().encode(value)), value)
        XCTAssertNotEqual(ControlJSON.bool(true), .number(1))
    }

    func testEnvelopeValidation() throws {
        let valid = Data(#"{"type":"request","id":"1","sessionId":"s","method":"getState","params":{},"extra":true}"#.utf8)
        XCTAssertEqual(try ControlRequest(data: valid).id, "1")
        for text in ["{}", "[]", "null", "", #"{"type":"request","id":1,"sessionId":"s","method":"getState","params":{}}"#,
                     #"{"type":"request","id":"","sessionId":"s","method":"getState","params":{}}"#,
                     #"{"type":"request","id":"1","sessionId":"s","method":"getState","params":[]}"#] {
            XCTAssertThrowsError(try ControlRequest(data: Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try ControlRequest(data: Data([0xff])))
    }

    func testVolumeValidationDoesNotCoerceBooleansOrStrings() throws {
        for value in [ControlJSON.bool(true), .string("0.5"), .number(-0.1), .number(1.01), .number(.infinity), .number(.nan), .null] {
            assertFailure("invalidParams") {
                try ControlCommand.parse(method: "setAppVolume", params: ["appId": .string("app"), "volume": value])
            }
        }
        XCTAssertEqual(try ControlCommand.parse(method: "setAppVolume", params: ["appId": .string("app"), "volume": .number(0)]), .volume("app", nil, 0))
        XCTAssertEqual(try ControlCommand.parse(method: "setAppVolume", params: ["appId": .string("app"), "volume": .number(1), "pid": .number(12)]), .volume("app", 12, 1))
    }

    func testPIDMuteAndRoutingValidation() throws {
        for pid in [ControlJSON.bool(true), .number(0), .number(-1), .number(1.2), .number(Double(Int32.max) + 1), .string("1"), .null] {
            assertFailure("invalidParams") {
                try ControlCommand.parse(method: "setAppMute", params: ["appId": .string("a"), "pid": pid, "muted": .bool(true)])
            }
        }
        assertFailure("invalidParams") { try ControlCommand.parse(method: "setAppMute", params: ["appId": .string("a"), "muted": .number(1)]) }
        assertFailure("unsupportedRouting") {
            try ControlCommand.parse(method: "setAppRouting", params: ["appId": .string("a"), "routing": .object(["mode": .string("multi")])])
        }
        assertFailure("invalidParams") { try ControlCommand.parse(method: "setPreferredInput", params: ["deviceUID": .string("")]) }
        assertFailure("unknownMethod") { try ControlCommand.parse(method: "reset", params: [:]) }
        XCTAssertEqual(try ControlCommand.parse(method: "setAppRouting", params: ["appId": .string("a"), "routing": .object(["mode": .string("followDefault")])]), .routing("a", nil, nil))
        XCTAssertEqual(try ControlCommand.parse(method: "setAppRouting", params: ["appId": .string("a"), "routing": .object(["mode": .string("single"), "deviceUID": .string("o")])]), .routing("a", nil, "o"))
    }

    private func assertFailure(_ code: String, _ action: () throws -> ControlCommand, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, code, file: file, line: line)
        }
    }
}
