// FineTune/Audio/Extensions/AudioDeviceID+Classification.swift
import AppKit
import AudioToolbox

// MARK: - Device Classification

nonisolated extension AudioDeviceID {
    func isAggregateDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var classID: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &classID)
        guard err == noErr else { return false }
        return classID == kAudioAggregateDeviceClassID
    }

    func isVirtualDevice() -> Bool {
        readTransportType() == .virtual
    }

    /// Returns the UIDs of an aggregate device's constituent hardware sub-devices,
    /// in the aggregate's channel order, or `nil` if this is not an aggregate.
    ///
    /// Used to *flatten* a user-created aggregate before wrapping it in FineTune's own
    /// private aggregate: CoreAudio does not allow an aggregate device to contain another
    /// aggregate as a sub-device (the wrapping aggregate ends up reporting 0 output
    /// channels), so the sub-devices must be expanded into FineTune's aggregate directly.
    func aggregateSubDeviceUIDs() -> [String]? {
        guard isAggregateDevice() else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return nil }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return nil }

        // kAudioAggregateDevicePropertyFullSubDeviceList returns a +1-retained CFArray of
        // CFString UIDs; takeRetainedValue transfers ownership to ARC.
        var unmanaged: Unmanaged<CFArray>?
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &unmanaged)
        guard err == noErr, let uids = unmanaged?.takeRetainedValue() as? [String], !uids.isEmpty else {
            return nil
        }
        return uids
    }

    func isBluetoothDevice() -> Bool {
        let t = readTransportType()
        return t == .bluetooth || t == .bluetoothLE
    }

    func isHidden() -> Bool {
        (try? readBool(kAudioDevicePropertyIsHidden)) ?? false
    }
}

// MARK: - AutoEQ Eligibility

extension AudioDeviceID {
    /// Returns `true` when FineTune should expose AutoEQ correction controls for this device.
    /// HDMI, DisplayPort, AirPlay, virtual, and known speaker-only devices return `false`.
    /// Built-in audio is allowed so Mac speakers and built-in jack headphones can be corrected.
    func supportsAutoEQ() -> Bool {
        let transport = readTransportType()

        switch transport {
        case .hdmi, .displayPort, .airPlay, .virtual:
            return false
        case .builtIn:
            return true
        default:
            break
        }

        // Exclude known speaker-only devices by name
        let name = (try? readDeviceName()) ?? ""
        let excludedNames = ["HomePod", "Apple TV", "Studio Display", "Pro Display XDR"]
        for excluded in excludedNames {
            if name.localizedCaseInsensitiveContains(excluded) { return false }
        }

        // Bluetooth, USB, Thunderbolt, aggregate, unknown → likely headphones
        return true
    }

    /// Checks if the built-in audio device currently has headphones plugged in
    /// by reading the active data source ID.
    func builtInHasHeadphonesActive() -> Bool {
        guard let sourceID: UInt32 = try? read(
            kAudioDevicePropertyDataSource,
            scope: .output,
            defaultValue: 0
        ), sourceID != 0 else {
            return false
        }

        // 0x6864706E = 'hdpn' — CoreAudio-internal FourCC for headphones, language-independent
        return sourceID == 0x6864706E
    }
}
// MARK: - Device Icon

extension AudioDeviceID {
    func readDeviceIcon() -> NSImage? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIcon,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        var iconURL: Unmanaged<CFURL>?
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &iconURL)

        // CoreAudio returns CF objects with +1 retain; takeRetainedValue transfers ownership to ARC
        guard err == noErr, let url = iconURL?.takeRetainedValue() as URL? else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    /// Returns an appropriate SF Symbol name based on device name and transport type.
    /// Used as fallback when kAudioDevicePropertyIcon is not available.
    func suggestedIconSymbol() -> String {
        let name = (try? readDeviceName()) ?? ""
        let transport = readTransportType()
        return Self.iconSymbol(forName: name, transport: transport)
    }

    /// Pure name + transport → SF Symbol mapping, extracted from `suggestedIconSymbol()`
    /// so the user-visible device-name cascade is unit-testable without a live device.
    static func iconSymbol(forName name: String, transport: TransportType) -> String {
        // AirPods variants
        if name.contains("AirPods Pro") { return "airpodspro" }
        if name.contains("AirPods Max") { return "airpodsmax" }
        if name.contains("AirPods") { return "airpods.gen3" }

        // HomePod variants
        if name.contains("HomePod mini") { return "homepodmini" }
        if name.contains("HomePod") { return "homepod" }

        // Apple TV
        if name.contains("Apple TV") { return "appletv" }

        // Beats
        if name.contains("Beats") { return "beats.headphones" }
        
        // Mac variants
        if name.contains("Mac Studio") { return "macstudio.fill" }
        if name.contains("Mac mini") { return "macmini.fill" }
        if name.contains("MacBook") { return "macbook" }
        if name.contains("iMac") { return "desktopcomputer" }
        
        // Display speakers
        if name.contains("Studio Display") { return "display" }
        if name.contains("Pro Display XDR") { return "display" }

        // Fall back to transport type default
        return transport.defaultIconSymbol
    }

    /// Returns an appropriate SF Symbol name for input devices based on device name and transport type.
    /// Used as fallback when kAudioDevicePropertyIcon is not available.
    func suggestedInputIconSymbol() -> String {
        let name = (try? readDeviceName()) ?? ""
        let transport = readTransportType()

        // iPhone (Continuity Camera)
        if name.contains("iPhone") { return "iphone" }

        // iPad
        if name.contains("iPad") { return "ipad" }

        // AirPods variants (work as both input/output)
        if name.contains("AirPods Pro") { return "airpodspro" }
        if name.contains("AirPods Max") { return "airpodsmax" }
        if name.contains("AirPods") { return "airpods.gen3" }

        // Beats
        if name.contains("Beats") { return "beats.headphones" }

        // MacBook built-in
        if name.contains("MacBook") { return "laptopcomputer" }
        
        // Display mic
        if name.contains("Studio Display") { return "display" }
        if name.contains("Pro Display XDR") { return "display" }

        // Transport-based fallbacks
        switch transport {
        case .builtIn:
            return "mic"
        case .usb:
            return "cable.connector"
        case .bluetooth, .bluetoothLE:
            return "mic"
        default:
            return "mic"
        }
    }
}
