// FineTune/Models/DeviceIconCatalog.swift
import AudioToolbox
import Foundation

enum DeviceIconCatalog {
    struct Entry: Identifiable, Equatable {
        let symbol: String
        let keywords: [String]
        var id: String { symbol }
    }

    struct Category: Identifiable {
        let id: String
        let name: LocalizedStringResource
        let entries: [Entry]
    }

    static let categories: [Category] = [
        Category(id: "headphones", name: "Headphones & Earbuds", entries: [
            Entry(symbol: "headphones", keywords: ["headphones", "cans", "over-ear"]),
            Entry(symbol: "airpodspro", keywords: ["airpods", "pro", "earbuds"]),
            Entry(symbol: "airpodsmax", keywords: ["airpods", "max", "over-ear"]),
            Entry(symbol: "airpods", keywords: ["airpods", "earbuds"]),
            Entry(symbol: "airpods.gen3", keywords: ["airpods", "earbuds"]),
            Entry(symbol: "airpods.gen4", keywords: ["airpods", "earbuds"]),
            Entry(symbol: "airpod.left", keywords: ["airpod", "left", "earbud"]),
            Entry(symbol: "airpod.right", keywords: ["airpod", "right", "earbud"]),
            Entry(symbol: "airpodspro.chargingcase.wireless.fill", keywords: ["airpods", "case", "charging"]),
            Entry(symbol: "airpods.chargingcase.wireless.fill", keywords: ["airpods", "case", "charging"]),
            Entry(symbol: "earpods", keywords: ["earpods", "wired", "apple"]),
            Entry(symbol: "earbuds", keywords: ["earbuds", "in-ear"]),
            Entry(symbol: "earbuds.case.fill", keywords: ["earbuds", "case"]),
            Entry(symbol: "beats.headphones", keywords: ["beats", "headphones"]),
            Entry(symbol: "beats.earphones", keywords: ["beats", "earphones", "earbuds"]),
            Entry(symbol: "beats.powerbeatspro", keywords: ["beats", "powerbeats", "sport"]),
            Entry(symbol: "beats.powerbeats", keywords: ["beats", "powerbeats", "sport"]),
            Entry(symbol: "beats.studiobuds", keywords: ["beats", "studio", "buds"]),
            Entry(symbol: "beats.solobuds", keywords: ["beats", "solo", "buds"]),
            Entry(symbol: "beats.fitpro", keywords: ["beats", "fit", "sport"]),
            Entry(symbol: "hearingdevice.ear", keywords: ["hearing", "aid", "ear"]),
        ]),
        Category(id: "speakers", name: "Speakers", entries: [
            Entry(symbol: "hifispeaker", keywords: ["speaker", "hifi"]),
            Entry(symbol: "hifispeaker.fill", keywords: ["speaker", "hifi"]),
            Entry(symbol: "hifispeaker.2", keywords: ["speakers", "stereo", "pair"]),
            Entry(symbol: "hifispeaker.2.fill", keywords: ["speakers", "stereo", "pair"]),
            Entry(symbol: "homepod.fill", keywords: ["homepod", "speaker"]),
            Entry(symbol: "homepod.2.fill", keywords: ["homepod", "stereo", "pair"]),
            Entry(symbol: "homepodmini.fill", keywords: ["homepod", "mini", "speaker"]),
            Entry(symbol: "homepodmini.2.fill", keywords: ["homepod", "mini", "stereo", "pair"]),
            Entry(symbol: "homepod.and.homepodmini.fill", keywords: ["homepod", "pair", "stereo"]),
            Entry(symbol: "speaker.fill", keywords: ["speaker"]),
            Entry(symbol: "speaker.wave.1.fill", keywords: ["speaker", "quiet"]),
            Entry(symbol: "speaker.wave.2.fill", keywords: ["speaker", "volume"]),
            Entry(symbol: "speaker.wave.3.fill", keywords: ["speaker", "loud"]),
            Entry(symbol: "beats.pill", keywords: ["beats", "pill", "speaker"]),
            Entry(symbol: "radio.fill", keywords: ["radio", "boombox"]),
            Entry(symbol: "tv.and.hifispeaker.fill", keywords: ["tv", "soundbar", "home theater"]),
            Entry(symbol: "hifispeaker.and.appletv.fill", keywords: ["apple tv", "home theater", "speaker"]),
            Entry(symbol: "hifireceiver.fill", keywords: ["receiver", "amp", "home theater"]),
        ]),
        Category(id: "computers-displays", name: "Computers & Displays", entries: [
            Entry(symbol: "macbook", keywords: ["macbook", "laptop"]),
            Entry(symbol: "laptopcomputer", keywords: ["laptop", "notebook"]),
            Entry(symbol: "desktopcomputer", keywords: ["imac", "desktop"]),
            Entry(symbol: "macstudio.fill", keywords: ["mac", "studio"]),
            Entry(symbol: "macmini.fill", keywords: ["mac", "mini"]),
            Entry(symbol: "macpro.gen3.fill", keywords: ["mac", "pro", "tower"]),
            Entry(symbol: "display", keywords: ["display", "monitor", "screen"]),
            Entry(symbol: "display.2", keywords: ["displays", "monitors", "dual"]),
            Entry(symbol: "tv", keywords: ["tv", "television", "hdmi"]),
            Entry(symbol: "tv.fill", keywords: ["tv", "television", "hdmi"]),
            Entry(symbol: "appletv.fill", keywords: ["apple tv", "airplay"]),
            Entry(symbol: "iphone", keywords: ["iphone", "phone", "continuity"]),
            Entry(symbol: "ipad", keywords: ["ipad", "tablet"]),
            Entry(symbol: "visionpro", keywords: ["vision", "pro", "spatial"]),
            Entry(symbol: "videoprojector.fill", keywords: ["projector", "beamer", "hdmi"]),
        ]),
        Category(id: "microphones", name: "Microphones", entries: [
            Entry(symbol: "mic", keywords: ["mic", "microphone"]),
            Entry(symbol: "mic.fill", keywords: ["mic", "microphone"]),
            Entry(symbol: "music.microphone", keywords: ["mic", "vocal", "studio"]),
            Entry(symbol: "mic.circle.fill", keywords: ["mic", "microphone"]),
            Entry(symbol: "mic.square.fill", keywords: ["mic", "microphone"]),
            Entry(symbol: "waveform.and.mic", keywords: ["mic", "voice", "recording"]),
            Entry(symbol: "web.camera.fill", keywords: ["webcam", "camera"]),
            Entry(symbol: "headset", keywords: ["headset", "boom", "gaming", "calls"]),
        ]),
        Category(id: "connectors-other", name: "Connectors & Other", entries: [
            Entry(symbol: "cable.connector", keywords: ["cable", "jack", "aux", "3.5mm"]),
            Entry(symbol: "cable.connector.horizontal", keywords: ["cable", "jack", "aux"]),
            Entry(symbol: "cable.coaxial", keywords: ["cable", "coaxial", "spdif"]),
            Entry(symbol: "bolt.horizontal", keywords: ["thunderbolt"]),
            Entry(symbol: "waveform", keywords: ["waveform", "virtual", "audio"]),
            Entry(symbol: "waveform.circle.fill", keywords: ["waveform", "virtual", "audio"]),
            Entry(symbol: "dot.radiowaves.left.and.right", keywords: ["wireless", "signal"]),
            Entry(symbol: "antenna.radiowaves.left.and.right", keywords: ["antenna", "broadcast"]),
            Entry(symbol: "airplayaudio", keywords: ["airplay", "audio"]),
            Entry(symbol: "airplayvideo", keywords: ["airplay", "video"]),
            Entry(symbol: "gamecontroller.fill", keywords: ["game", "controller", "console"]),
            Entry(symbol: "car.fill", keywords: ["car", "auto"]),
            Entry(symbol: "car.side.fill", keywords: ["car", "auto"]),
            Entry(symbol: "guitars.fill", keywords: ["guitar", "instrument", "amp"]),
            Entry(symbol: "pianokeys", keywords: ["piano", "keyboard", "midi"]),
            Entry(symbol: "amplifier", keywords: ["amp", "amplifier", "guitar"]),
            Entry(symbol: "slider.vertical.3", keywords: ["mixer", "faders", "interface"]),
            Entry(symbol: "dial.medium.fill", keywords: ["knob", "gain", "interface", "amp"]),
            Entry(symbol: "recordingtape", keywords: ["tape", "recorder", "recording"]),
            Entry(symbol: "megaphone.fill", keywords: ["megaphone", "pa", "announcement"]),
            Entry(symbol: "tuningfork", keywords: ["tuning", "fork", "pitch"]),
            Entry(symbol: "music.note", keywords: ["music", "note"]),
            Entry(symbol: "opticaldisc.fill", keywords: ["cd", "disc", "player"]),
        ]),
    ]

    static let allEntries: [Entry] = categories.flatMap(\.entries)

    private static let entryBySymbol: [String: Entry] =
        Dictionary(uniqueKeysWithValues: allEntries.map { ($0.symbol, $0) })

    static func entry(for symbol: String) -> Entry? {
        entryBySymbol[symbol]
    }

    /// An empty or whitespace-only query returns the full catalog.
    static func matching(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allEntries }
        return allEntries.filter { entry in
            entry.symbol.lowercased().contains(q)
                || entry.keywords.contains { $0.lowercased().contains(q) }
        }
    }

    /// Ordered best guesses for a device, shown in the picker's Suggested
    /// section. The automatic name/transport guess always leads so the
    /// highlighted "current" symbol appears first. That guess comes from
    /// `AudioDeviceID.iconSymbol`, so the result may include valid SF Symbol
    /// names that are not catalog entries (e.g. "homepod", "appletv").
    static func suggested(forName name: String, transport: TransportType) -> [String] {
        var result = [AudioDeviceID.iconSymbol(forName: name, transport: transport)]

        let family: [String]
        switch transport {
        case .bluetooth, .bluetoothLE:
            family = ["headphones", "airpodspro", "airpodsmax", "airpods.gen3",
                      "earbuds", "beats.headphones", "hifispeaker.fill", "headset"]
        case .usb:
            family = ["headphones", "mic.fill", "cable.connector", "amplifier",
                      "hifispeaker.fill", "headset", "slider.vertical.3"]
        case .builtIn:
            family = ["macbook", "laptopcomputer", "desktopcomputer", "hifispeaker", "mic.fill"]
        case .hdmi, .displayPort:
            family = ["tv", "display", "tv.and.hifispeaker.fill", "display.2", "videoprojector.fill"]
        case .airPlay:
            family = ["airplayaudio", "homepod.fill", "homepodmini.fill",
                      "appletv.fill", "tv.and.hifispeaker.fill", "homepod.2.fill"]
        case .virtual:
            family = ["waveform", "waveform.circle.fill", "dot.radiowaves.left.and.right", "music.note"]
        case .thunderbolt:
            family = ["bolt.horizontal", "amplifier", "cable.connector", "hifispeaker.fill"]
        case .aggregate:
            family = ["speaker.wave.2.fill", "hifispeaker.2.fill", "waveform"]
        case .unknown:
            family = ["hifispeaker", "headphones", "speaker.wave.2.fill"]
        }

        for symbol in family where !result.contains(symbol) {
            result.append(symbol)
        }
        return result
    }
}
