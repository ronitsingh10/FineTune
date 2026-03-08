import Foundation
import IOBluetooth
import IOKit

@MainActor
final class BluetoothDeviceController {
    static let shared = BluetoothDeviceController()

    private init() {}

    /// Best-effort disconnect for a Bluetooth device matching the provided audio device name.
    /// Returns true if any matching connected Bluetooth device was disconnected.
    func disconnectDevice(matchingAudioDeviceName audioDeviceName: String) -> Bool {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return false
        }

        let normalizedTarget = normalizedName(audioDeviceName)
        let exactMatches = paired.filter {
            normalizedName($0.nameOrAddress ?? "") == normalizedTarget
        }
        let partialMatches = paired.filter {
            let candidate = normalizedName($0.nameOrAddress ?? "")
            return candidate.contains(normalizedTarget) || normalizedTarget.contains(candidate)
        }

        let candidates = exactMatches.isEmpty ? partialMatches : exactMatches
        var disconnectedAny = false

        for device in candidates where device.isConnected() {
            let status = device.closeConnection()
            if status == kIOReturnSuccess {
                disconnectedAny = true
            }
        }

        return disconnectedAny
    }

    private func normalizedName(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
