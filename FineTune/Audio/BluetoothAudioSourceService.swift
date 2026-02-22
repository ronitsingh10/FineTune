import AppKit
import IOBluetooth
import IOKit
import os

@MainActor
final class BluetoothAudioSourceService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "BluetoothAudioSourceService")

    /// Returns paired Bluetooth audio devices that are not currently connected.
    func unconnectedPairedAudioSources(excludingConnectedNames connectedNames: Set<String>) -> [BluetoothAudioSource] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        let sources = paired.compactMap { device -> BluetoothAudioSource? in
            let name = device.nameOrAddress ?? device.name ?? device.addressString ?? "Bluetooth Audio"
            let isConnected = device.isConnected()
            let isAudio = isLikelyAudioDevice(device, name: name)
            let inCoreAudioList = connectedNames.contains(name)

            guard !isConnected else {
                return nil
            }
            guard isAudio else {
                return nil
            }
            guard !inCoreAudioList else {
                return nil
            }
            guard let address = device.addressString else {
                return nil
            }

            let iconName = name.contains("AirPods") ? "airpods.gen3" : "headphones"
            let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: name)
            return BluetoothAudioSource(address: address, name: name, icon: icon)
        }

        return sources.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func connect(_ source: BluetoothAudioSource) {
        guard let device = IOBluetoothDevice(addressString: source.address) else {
            logger.error("Cannot resolve Bluetooth device for address \(source.address)")
            return
        }

        guard !device.isConnected() else { return }

        Task.detached(priority: .userInitiated) {
            let status = device.openConnection()
            if status != kIOReturnSuccess && !device.isConnected() {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "BluetoothAudioSourceService")
                    .error("Bluetooth connect failed for \(source.name, privacy: .public): \(status)")
            }
        }
    }

    private func isLikelyAudioDevice(_ device: IOBluetoothDevice, name: String) -> Bool {
        let major = Int(device.deviceClassMajor)
        if major == kBluetoothDeviceClassMajorAudio {
            return true
        }

        let audioServiceMask = UInt32(kBluetoothServiceClassMajorAudio)
        if (device.serviceClassMajor & audioServiceMask) != 0 {
            return true
        }

        let lowered = name.lowercased()
        let audioKeywords = [
            "airpods", "beats", "headphone", "headset", "earbud", "buds",
            "speaker", "soundbar", "homepod"
        ]
        return audioKeywords.contains { lowered.contains($0) }
    }
}
