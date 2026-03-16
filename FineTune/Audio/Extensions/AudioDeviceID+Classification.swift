// FineTune/Audio/Extensions/AudioDeviceID+Classification.swift
import AppKit
import AudioToolbox

// MARK: - Device Classification

extension AudioDeviceID {
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

    func isHidden() -> Bool {
        (try? readBool(kAudioDevicePropertyIsHidden)) ?? false
    }
}

// MARK: - AutoEQ Eligibility

extension AudioDeviceID {
    /// Returns `true` if this device is likely headphones and can benefit from AutoEQ correction.
    /// HDMI, DisplayPort, AirPlay, virtual, and known speaker-only devices return `false`.
    /// Built-in devices delegate to `builtInHasHeadphonesActive()` for headphone jack detection.
    func supportsAutoEQ() -> Bool {
        let transport = readTransportType()

        switch transport {
        case .hdmi, .displayPort, .airPlay, .virtual:
            return false
        case .builtIn:
            return builtInHasHeadphonesActive()
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
    /// by reading the active data source name.
    func builtInHasHeadphonesActive() -> Bool {
        // Read the active data source ID
        guard let sourceID: UInt32 = try? read(
            kAudioDevicePropertyDataSource,
            scope: .output,
            defaultValue: 0
        ), sourceID != 0 else {
            // API failure — safer to not apply headphone correction to speakers
            return false
        }

        // Resolve data source ID to a name string
        guard let sourceName = readStringWithQualifier(
            kAudioDevicePropertyDataSourceNameForIDCFString,
            scope: .output,
            qualifier: sourceID
        ) else {
            return false
        }

        return sourceName.localizedCaseInsensitiveContains("headphone")
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
