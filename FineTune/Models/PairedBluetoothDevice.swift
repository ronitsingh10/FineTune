// FineTune/Models/PairedBluetoothDevice.swift
import AppKit

/// A Bluetooth device that is paired with macOS but not currently connected.
/// These devices are not visible in the CoreAudio HAL.
struct PairedBluetoothDevice: Identifiable, Hashable {
    /// MAC address string "XX:XX:XX:XX:XX:XX" — stable identity across sessions
    let id: String
    let name: String
    let icon: NSImage?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
