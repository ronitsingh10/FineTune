import Foundation

nonisolated enum AlertVolumeAutomation {
    static func decode(_ data: Data, requested: Int) throws -> Float {
        guard let text = String(data: data, encoding: .utf8),
            let observed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            (0...100).contains(observed), observed == requested
        else { throw AutomationError(.unavailable, "Alert volume readback was not confirmed") }
        return Float(observed) / 100
    }
    static func write(percent: Int) async throws -> Float {
        guard (0...100).contains(percent) else {
            throw AutomationError(.invalidParameter, "Alert volume must be 0...100")
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "set volume alert volume \(percent)\nget alert volume of (get volume settings)",
            ]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output.fileHandleForReading.readDataToEndOfFile())
                } else {
                    continuation.resume(
                        throwing: AutomationError(.unavailable, "macOS refused alert volume control"))
                }
            }
            do { try process.run() } catch {
                continuation.resume(
                    throwing: AutomationError(.unavailable, "Could not start alert volume control"))
            }
        }
        try Task.checkCancellation()
        return try decode(data, requested: percent)
    }
}
