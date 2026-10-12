import Foundation
import Testing

@testable import FineTune

@Suite("Automation protocol")
struct AutomationProtocolTests {
    @Test func roundTripRequest() throws {
        let data = Data(
            #"{"apiVersion":1,"id":"42","method":"app.volume.set","params":{"percent":30,"target":{"appId":"com.apple.Music"}}}"#
                .utf8)
        let request = try JSONDecoder().decode(AutomationRequest.self, from: data)
        #expect(request.id == "42")
        #expect(request.params["percent"] == .number(30))
        #expect(
            try JSONDecoder().decode(AutomationRequest.self, from: JSONEncoder().encode(request)) == request)
    }
    @Test func rejectsAmbiguousResponse() {
        let data = Data(
            #"{"apiVersion":1,"id":"x","result":{},"error":{"code":"invalid_parameter","message":"bad"}}"#
                .utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AutomationResponse.self, from: data) }
    }
    @Test func requiresResponseOutcome() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AutomationResponse.self, from: Data(#"{"apiVersion":1,"id":"x"}"#.utf8))
        }
    }
    @Test func validatesVersionAndUnits() throws {
        #expect(throws: AutomationError.self) {
            try AutomationRequest(apiVersion: 2, id: "1", method: "state.get", params: [:]).validate()
        }
        #expect(try AutomationParameters(["percent": .number(0)]).number("percent", range: 0...100) == 0)
        #expect(try AutomationParameters(["percent": .number(100)]).number("percent", range: 0...100) == 100)
        #expect(throws: AutomationError.self) {
            try AutomationParameters(["percent": .number(101)]).number("percent", range: 0...100)
        }
        #expect(throws: AutomationError.self) {
            try AutomationParameters(["percent": .number(.infinity)]).number("percent", range: 0...100)
        }
        #expect(throws: AutomationError.self) {
            try AutomationParameters(["boost": .number(2.5)]).integer("boost", values: [1, 2, 3, 4])
        }
        #expect(try AutomationParameters(["gainDB": .number(-12)]).number("gainDB", range: -12...12) == -12)
        #expect(throws: AutomationError.self) {
            try AutomationParameters(["gainDB": .number(12.1)]).number("gainDB", range: -12...12)
        }
    }
    @Test func targetMustHaveOneIdentity() {
        #expect(throws: AutomationError.self) {
            try AutomationTarget.parse(.object(["appId": .string("a"), "deviceUID": .string("d")]))
        }
        #expect(throws: AutomationError.self) { try AutomationTarget.parse(.object([:])) }
    }
}
