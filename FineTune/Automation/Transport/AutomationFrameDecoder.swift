import Foundation

nonisolated struct AutomationFrameDecoder {
    static let maximumFrame = 1_048_576
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [AutomationRequest] {
        buffer.append(bytes)
        var requests: [AutomationRequest] = []
        while let end = buffer.firstIndex(of: 10) {
            let length = buffer.distance(from: buffer.startIndex, to: end)
            guard length <= Self.maximumFrame else {
                throw AutomationError(.invalidRequest, "Frame too large")
            }
            let frame = Data(buffer.prefix(length))
            buffer.removeFirst(length + 1)
            guard !frame.isEmpty, String(data: frame, encoding: .utf8) != nil else {
                throw AutomationError(.invalidRequest, "Invalid UTF-8 frame")
            }
            do {
                let request = try JSONDecoder().decode(AutomationRequest.self, from: frame)
                try request.validate()
                requests.append(request)
            } catch let e as AutomationError { throw e } catch {
                throw AutomationError(.invalidRequest, "Invalid JSON request")
            }
            guard requests.count <= 100 else { throw AutomationError(.busy, "Too many frames in one read") }
        }
        guard buffer.count <= Self.maximumFrame else {
            throw AutomationError(.invalidRequest, "Frame too large")
        }
        return requests
    }
}
