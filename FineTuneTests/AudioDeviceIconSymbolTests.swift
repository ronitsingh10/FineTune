// FineTuneTests/AudioDeviceIconSymbolTests.swift

import Testing
import AudioToolbox
@testable import FineTune

@Suite("AudioDeviceID.iconSymbol(forName:transport:)")
struct AudioDeviceIconSymbolTests {

    @Test("Device name maps to the expected SF Symbol", arguments: [
        ("AirPods Pro", "airpodspro"),
        ("Someone's AirPods Max", "airpodsmax"),
        ("AirPods", "airpods.gen3"),
        ("HomePod mini", "homepodmini"),
        ("Living Room HomePod", "homepod"),
        ("Apple TV 4K", "appletv"),
        ("Beats Studio Pro", "beats.headphones"),
        ("Mac Studio Speakers", "macstudio.fill"),
        ("Mac mini", "macmini.fill"),
        ("MacBook Pro Speakers", "macbook"),
        ("iMac", "desktopcomputer"),
        ("Studio Display", "display"),
        ("Pro Display XDR", "display"),
    ])
    func mapsKnownNames(name: String, expected: String) {
        #expect(AudioDeviceID.iconSymbol(forName: name, transport: .unknown) == expected)
    }

    // The cascade is ordered most-specific-first; a reorder would silently mis-map a
    // shipping device, so pin the precedences that actually overlap.
    @Test("More specific names win over their prefixes")
    func cascadeOrdering() {
        #expect(AudioDeviceID.iconSymbol(forName: "AirPods Pro", transport: .unknown) == "airpodspro")
        #expect(AudioDeviceID.iconSymbol(forName: "AirPods Max", transport: .unknown) == "airpodsmax")
        #expect(AudioDeviceID.iconSymbol(forName: "HomePod mini", transport: .unknown) == "homepodmini")
    }

    @Test("Unrecognised name falls back to the transport-type symbol", arguments: [
        (TransportType.builtIn, "hifispeaker"),
        (TransportType.bluetooth, "headphones"),
        (TransportType.airPlay, "airplayaudio"),
        (TransportType.hdmi, "tv"),
        (TransportType.unknown, "hifispeaker"),
    ])
    func unknownNameUsesTransport(transport: TransportType, expected: String) {
        #expect(AudioDeviceID.iconSymbol(forName: "Generic USB Audio", transport: transport) == expected)
    }
}
