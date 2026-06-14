// FineTune/Views/MenuBar/MenuBarDeviceIconResolver.swift

import AudioToolbox

struct MenuBarDeviceIconResolver {
    // Neutral "unknown output" glyph, sourced from the transport-type convention
    // so it stays in sync with the rest of the app rather than a private literal.
    static let fallbackSymbol = TransportType.unknown.defaultIconSymbol

    static func resolveSymbol(
        priorityOrder: [String],
        outputDevices: [AudioDevice],
        defaultDeviceID: AudioDeviceID,
        isDeviceAvailable: (AudioDevice) -> Bool = { $0.id.isDeviceAlive() },
        symbolForDevice: (AudioDevice) -> String = { $0.id.suggestedIconSymbol() },
        symbolForDefaultID: (AudioDeviceID) -> String = { id in
            guard id.isValid else { return Self.fallbackSymbol }
            return id.suggestedIconSymbol()
        }
    ) -> String {
        let devicesByUID = Dictionary(outputDevices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Match macOS's sound menu: the persistent icon represents the device
        // currently receiving system audio, even if FineTune's saved priority
        // order has another connected device above it.
        if let defaultDevice = outputDevices.first(where: { $0.id == defaultDeviceID }),
           isDeviceAvailable(defaultDevice) {
            return symbolForDevice(defaultDevice)
        }

        for uid in priorityOrder {
            guard let device = devicesByUID[uid], isDeviceAvailable(device) else { continue }
            return symbolForDevice(device)
        }

        if defaultDeviceID.isValid {
            return symbolForDefaultID(defaultDeviceID)
        }

        return fallbackSymbol
    }
}
