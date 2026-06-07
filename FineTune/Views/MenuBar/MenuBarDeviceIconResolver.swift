// FineTune/Views/MenuBar/MenuBarDeviceIconResolver.swift

import AudioToolbox

struct MenuBarDeviceIconResolver {
    static let fallbackSymbol = "hifispeaker"

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

        for uid in priorityOrder {
            guard let device = devicesByUID[uid], isDeviceAvailable(device) else { continue }
            return symbolForDevice(device)
        }

        if let defaultDevice = outputDevices.first(where: { $0.id == defaultDeviceID }), isDeviceAvailable(defaultDevice) {
            return symbolForDevice(defaultDevice)
        }

        if defaultDeviceID.isValid {
            return symbolForDefaultID(defaultDeviceID)
        }

        return fallbackSymbol
    }
}
