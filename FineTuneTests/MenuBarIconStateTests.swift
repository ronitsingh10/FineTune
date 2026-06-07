// FineTuneTests/MenuBarIconStateTests.swift
// Tests for MenuBarIconState value types — bucket thresholds, symbol mapping,
// and per-style baseline derivation.

import Testing
@testable import FineTune

// MARK: - VolumeBucket

@Suite("VolumeBucket — boundary correctness")
struct VolumeBucketBoundaryTests {

    @Test("0.0 maps to zero")
    func zeroVolume() {
        #expect(VolumeBucket.bucket(for: 0.0) == .zero)
    }

    @Test("Just below 0.01 is still zero")
    func justBelowOnePercent() {
        #expect(VolumeBucket.bucket(for: 0.009) == .zero)
    }

    @Test("0.01 crosses to low")
    func oneBoundary() {
        #expect(VolumeBucket.bucket(for: 0.01) == .low)
    }

    @Test("Just below 0.34 is low")
    func justBelowLowMidBoundary() {
        #expect(VolumeBucket.bucket(for: 0.33) == .low)
    }

    @Test("0.34 crosses to mid")
    func lowMidBoundary() {
        #expect(VolumeBucket.bucket(for: 0.34) == .mid)
    }

    @Test("Just below 0.67 is mid")
    func justBelowMidHighBoundary() {
        #expect(VolumeBucket.bucket(for: 0.66) == .mid)
    }

    @Test("0.67 crosses to high")
    func midHighBoundary() {
        #expect(VolumeBucket.bucket(for: 0.67) == .high)
    }

    @Test("1.0 is high")
    func fullVolume() {
        #expect(VolumeBucket.bucket(for: 1.0) == .high)
    }

    @Test("Out-of-range positive clamps to high")
    func overdrive() {
        #expect(VolumeBucket.bucket(for: 1.5) == .high)
    }

    @Test("NaN falls back to zero (prevents corrupted HAL read from lighting up wave.3.fill)")
    func notANumber() {
        #expect(VolumeBucket.bucket(for: .nan) == .zero)
    }

    @Test("Infinity falls back to zero")
    func infiniteVolume() {
        #expect(VolumeBucket.bucket(for: .infinity) == .zero)
    }

    @Test("Negative volume treated as zero bucket")
    func negativeVolume() {
        #expect(VolumeBucket.bucket(for: -1.0) == .zero)
    }
}

@Suite("VolumeBucket — symbol names")
struct VolumeBucketSymbolNameTests {

    @Test("zero bucket uses speaker.fill (no wave lines)")
    func zeroSymbol() {
        #expect(VolumeBucket.zero.symbolName == "speaker.fill")
    }

    @Test("low bucket uses wave.1.fill")
    func lowSymbol() {
        #expect(VolumeBucket.low.symbolName == "speaker.wave.1.fill")
    }

    @Test("mid bucket uses wave.2.fill")
    func midSymbol() {
        #expect(VolumeBucket.mid.symbolName == "speaker.wave.2.fill")
    }

    @Test("high bucket uses wave.3.fill")
    func highSymbol() {
        #expect(VolumeBucket.high.symbolName == "speaker.wave.3.fill")
    }
}

// MARK: - MenuBarIconState.image

@Suite("MenuBarIconState — image derivation")
struct MenuBarIconStateImageTests {

    @Test("speakerVolume uses the bucket's symbol")
    func speakerVolumeImage() {
        #expect(MenuBarIconState.speakerVolume(.mid).image == .systemSymbol("speaker.wave.2.fill"))
        #expect(MenuBarIconState.speakerVolume(.zero).image == .systemSymbol("speaker.fill"))
    }

    @Test("speakerMuted uses speaker.slash.fill")
    func speakerMutedImage() {
        #expect(MenuBarIconState.speakerMuted.image == .systemSymbol("speaker.slash.fill"))
    }

    @Test("staticBaseline passes through")
    func staticBaselineImage() {
        #expect(MenuBarIconState.staticBaseline(.asset("X")).image == .asset("X"))
        #expect(MenuBarIconState.staticBaseline(.systemSymbol("waveform")).image == .systemSymbol("waveform"))
    }

    @Test("deviceFlash wraps an SF Symbol")
    func deviceFlashImage() {
        #expect(MenuBarIconState.deviceFlash(symbol: "airpodsmax").image == .systemSymbol("airpodsmax"))
    }

    @Test("device wraps an SF Symbol")
    func deviceImage() {
        #expect(MenuBarIconState.device(symbol: "airpodspro").image == .systemSymbol("airpodspro"))
    }
}

// MARK: - Style-dependent baseline

@Suite("MenuBarIconState.baseline — Speaker style (dynamic)")
struct SpeakerBaselineTests {

    @Test("Unmuted mid volume → speakerVolume(.mid)")
    func speakerUnmutedMid() {
        let state = MenuBarIconState.baseline(style: .speaker, volume: 0.5, muted: false)
        #expect(state == .speakerVolume(.mid))
    }

    @Test("Unmuted full volume → speakerVolume(.high)")
    func speakerUnmutedFull() {
        let state = MenuBarIconState.baseline(style: .speaker, volume: 1.0, muted: false)
        #expect(state == .speakerVolume(.high))
    }

    @Test("Unmuted zero volume → speakerVolume(.zero)")
    func speakerUnmutedZero() {
        let state = MenuBarIconState.baseline(style: .speaker, volume: 0.0, muted: false)
        #expect(state == .speakerVolume(.zero))
    }

    @Test("Muted at any volume → speakerMuted")
    func speakerMutedOverridesVolume() {
        for v in [Float(0.0), 0.2, 0.5, 0.8, 1.0] {
            let state = MenuBarIconState.baseline(style: .speaker, volume: v, muted: true)
            #expect(state == .speakerMuted, "volume=\(v)")
        }
    }
}

@Suite("MenuBarIconState.baseline — non-speaker styles (static)")
struct NonSpeakerBaselineTests {

    @Test(".default is asset regardless of volume")
    func defaultAsset() {
        let expected = MenuBarIconState.staticBaseline(.asset("MenuBarIcon"))
        for v in [Float(0.0), 0.25, 0.5, 0.75, 1.0] {
            #expect(MenuBarIconState.baseline(style: .default, volume: v, muted: false) == expected, "volume=\(v)")
        }
    }

    @Test(".default ignores mute (non-speaker styles keep static baseline)")
    func defaultIgnoresMute() {
        let expected = MenuBarIconState.staticBaseline(.asset("MenuBarIcon"))
        #expect(MenuBarIconState.baseline(style: .default, volume: 0.5, muted: true) == expected)
        #expect(MenuBarIconState.baseline(style: .default, volume: 0.0, muted: true) == expected)
    }

    @Test(".waveform is waveform symbol regardless of volume")
    func waveformSymbol() {
        let expected = MenuBarIconState.staticBaseline(.systemSymbol("waveform"))
        for v in [Float(0.0), 0.5, 1.0] {
            #expect(MenuBarIconState.baseline(style: .waveform, volume: v, muted: false) == expected, "volume=\(v)")
        }
    }

    @Test(".waveform ignores mute")
    func waveformIgnoresMute() {
        let expected = MenuBarIconState.staticBaseline(.systemSymbol("waveform"))
        #expect(MenuBarIconState.baseline(style: .waveform, volume: 0.5, muted: true) == expected)
    }

    @Test(".device is supplied device symbol regardless of volume")
    func deviceSymbol() {
        let expected = MenuBarIconState.device(symbol: "airpodspro")
        for v in [Float(0.0), 0.5, 1.0] {
            #expect(MenuBarIconState.baseline(style: .device, volume: v, muted: false, deviceSymbol: "airpodspro") == expected, "volume=\(v)")
        }
    }

    @Test(".device ignores mute")
    func deviceIgnoresMute() {
        let expected = MenuBarIconState.device(symbol: "homepod")
        #expect(MenuBarIconState.baseline(style: .device, volume: 0.5, muted: true, deviceSymbol: "homepod") == expected)
    }

    @Test(".equalizer is slider.vertical.3 regardless of volume")
    func equalizerSymbol() {
        let expected = MenuBarIconState.staticBaseline(.systemSymbol("slider.vertical.3"))
        for v in [Float(0.0), 0.5, 1.0] {
            #expect(MenuBarIconState.baseline(style: .equalizer, volume: v, muted: false) == expected, "volume=\(v)")
        }
    }

    @Test(".equalizer ignores mute")
    func equalizerIgnoresMute() {
        let expected = MenuBarIconState.staticBaseline(.systemSymbol("slider.vertical.3"))
        #expect(MenuBarIconState.baseline(style: .equalizer, volume: 0.5, muted: true) == expected)
    }
}

@Suite("MenuBarIconState — consistency with MenuBarIconStyle.iconName")
struct StyleIconNameConsistencyTests {

    /// Baseline symbols for non-speaker styles must match the pre-existing
    /// MenuBarIconStyle.iconName mapping so switching between dynamic and static
    /// codepaths produces the same visual for those styles.

    @Test(".default baseline image matches MenuBarIconStyle.default.iconName")
    func defaultMatches() {
        let baseline = MenuBarIconState.baseline(style: .default, volume: 0.5, muted: false)
        #expect(baseline.image == .asset(MenuBarIconStyle.default.iconName))
    }

    @Test(".waveform baseline image matches MenuBarIconStyle.waveform.iconName")
    func waveformMatches() {
        let baseline = MenuBarIconState.baseline(style: .waveform, volume: 0.5, muted: false)
        #expect(baseline.image == .systemSymbol(MenuBarIconStyle.waveform.iconName))
    }

    @Test(".equalizer baseline image matches MenuBarIconStyle.equalizer.iconName")
    func equalizerMatches() {
        let baseline = MenuBarIconState.baseline(style: .equalizer, volume: 0.5, muted: false)
        #expect(baseline.image == .systemSymbol(MenuBarIconStyle.equalizer.iconName))
    }

    @Test(".device baseline defaults to MenuBarIconStyle.device.iconName when no symbol supplied")
    func deviceMatchesDefaultIconName() {
        let baseline = MenuBarIconState.baseline(style: .device, volume: 0.5, muted: false)
        #expect(baseline.image == .systemSymbol(MenuBarIconStyle.device.iconName))
    }
}
