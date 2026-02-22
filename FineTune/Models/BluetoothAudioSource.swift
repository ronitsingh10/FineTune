import AppKit

/// A paired Bluetooth audio source that is currently not connected.
struct BluetoothAudioSource: Identifiable, Hashable {
    let address: String
    let name: String
    let icon: NSImage?

    var id: String { address }
}
