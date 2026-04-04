import Foundation
import IOBluetooth

@objc private protocol FineTunePrivateListeningModeSelectors {
    @objc optional var listeningMode: UInt8 { get set }
    @objc optional var isANCSupported: Bool { get }
    @objc optional var isTransparencySupported: Bool { get }
}

extension IOBluetoothDevice {
    var safeListeningMode: UInt8? {
        let selector = #selector(getter: FineTunePrivateListeningModeSelectors.listeningMode)
        guard responds(to: selector) else { return nil }
        guard let value = value(forKey: "listeningMode") as? NSNumber else { return nil }
        return value.uint8Value
    }

    func setSafeListeningMode(_ mode: UInt8) -> Bool {
        let selector = #selector(getter: FineTunePrivateListeningModeSelectors.listeningMode)
        guard responds(to: selector) else { return false }
        setValue(Int(mode), forKey: "listeningMode")
        return true
    }

    var isANCCapable: Bool {
        let selector = #selector(getter: FineTunePrivateListeningModeSelectors.isANCSupported)
        guard responds(to: selector) else { return false }
        return (value(forKey: "isANCSupported") as? NSNumber)?.boolValue ?? false
    }

    var isTransparencyCapable: Bool {
        let selector = #selector(getter: FineTunePrivateListeningModeSelectors.isTransparencySupported)
        guard responds(to: selector) else { return false }
        return (value(forKey: "isTransparencySupported") as? NSNumber)?.boolValue ?? false
    }

    var supportsAdaptive: Bool {
        let nameSelector = #selector(getter: IOBluetoothDevice.name)
        guard responds(to: nameSelector) else { return false }
        guard let deviceName = name else { return false }
        return deviceName.contains("AirPods Pro")
    }
}
