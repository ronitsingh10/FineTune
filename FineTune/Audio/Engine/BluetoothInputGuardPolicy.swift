import Foundation

/// Selection policy only. It never opens a microphone or claims to disable HFP.
nonisolated enum BluetoothInputGuardPolicy {
    struct Candidate: Equatable {
        let uid: String
        let builtIn: Bool
        let bluetooth: Bool
    }
    static func target(in devices: [Candidate]) -> String? {
        devices.first { $0.builtIn && !$0.bluetooth }?.uid
    }
    static func allowsInput(_ device: Candidate, enabled: Bool) -> Bool {
        !enabled || (device.builtIn && !device.bluetooth)
    }
    static func suggestsCallMode(sampleRate: Double) -> Bool {
        sampleRate > 0 && sampleRate < 44_100
    }
}
