// FineTune/Views/MenuBar/MenuBarIconState.swift
// Value types for the menu bar icon. Bucket thresholds mirror
// TahoeStyleHUD.waveIconName / ClassicStyleHUD.waveIconName.
// The AppKit NSImage bridge lives in MenuBarIconImage+NSImage.swift.

import Foundation

nonisolated enum MenuBarIconImage: Equatable {
    case systemSymbol(String)
    case asset(String)
}

nonisolated enum VolumeBucket: Equatable {
    case zero
    case low
    case mid
    case high

    static func bucket(for volume: Float) -> VolumeBucket {
        // NaN falls through to default in a `..<` switch. Force it to .zero so a
        // corrupted HAL read doesn't light up the icon at full volume.
        guard volume.isFinite else { return .zero }
        switch volume {
        case ..<0.01: return .zero
        case ..<0.34: return .low
        case ..<0.67: return .mid
        default:      return .high
        }
    }

    var symbolName: String {
        switch self {
        case .zero: return "speaker.fill"
        case .low:  return "speaker.wave.1.fill"
        case .mid:  return "speaker.wave.2.fill"
        case .high: return "speaker.wave.3.fill"
        }
    }
}

nonisolated enum MenuBarIconState: Equatable {
    case speakerVolume(VolumeBucket)
    case speakerMuted
    case staticBaseline(MenuBarIconImage)
    case deviceFlash(symbol: String)

    var image: MenuBarIconImage {
        switch self {
        case .speakerVolume(let bucket): return .systemSymbol(bucket.symbolName)
        case .speakerMuted:              return .systemSymbol("speaker.slash.fill")
        case .staticBaseline(let image): return image
        case .deviceFlash(let symbol):   return .systemSymbol(symbol)
        }
    }
}

// MARK: - Style → baseline mapping

extension MenuBarIconState {
    static func baseline(
        style: MenuBarIconStyle,
        volume: Float,
        muted: Bool
    ) -> MenuBarIconState {
        switch style {
        case .speaker:
            if muted { return .speakerMuted }
            return .speakerVolume(.bucket(for: volume))
        case .default:
            return .staticBaseline(.asset("MenuBarIcon"))
        case .waveform:
            return .staticBaseline(.systemSymbol("waveform"))
        case .equalizer:
            return .staticBaseline(.systemSymbol("slider.vertical.3"))
        }
    }
}
