// FineTuneTests/VolumeFeedbackTests.swift
// Decision logic for the volume-feedback pop. NSSound playback itself is
// verified manually — it needs a real output device and a listener.
import Testing
import Foundation
@testable import FineTune

@Suite("VolumeFeedback — shouldPlay modifier rule")
struct VolumeFeedbackShouldPlayTests {
    @Test("Shift alone inverts; Option follows pref", arguments: [
        (prefOn: true,  shift: false, option: false, expected: true),
        (prefOn: false, shift: false, option: false, expected: false),
        (prefOn: true,  shift: true,  option: false, expected: false),
        (prefOn: false, shift: true,  option: false, expected: true),
        (prefOn: true,  shift: true,  option: true,  expected: true),
        (prefOn: false, shift: true,  option: true,  expected: false),
        (prefOn: true,  shift: false, option: true,  expected: true),
        (prefOn: false, shift: false, option: true,  expected: false),
    ])
    func decisionTable(_ c: (prefOn: Bool, shift: Bool, option: Bool, expected: Bool)) {
        #expect(VolumeFeedback.shouldPlay(prefOn: c.prefOn, shiftHeld: c.shift, optionHeld: c.option) == c.expected)
    }
}

@Suite("VolumeFeedback — gain by tier")
struct VolumeFeedbackGainTests {
    @Test func hardwareTierPlaysFullScale() {
        #expect(VolumeFeedback.gain(tier: .hardware, sliderFraction: 0.3) == 1.0)
    }
    @Test func ddcTierPlaysFullScale() {
        #expect(VolumeFeedback.gain(tier: .ddc, sliderFraction: 0.3) == 1.0)
    }
    @Test func softwareTierMatchesTapMapping() {
        #expect(VolumeFeedback.gain(tier: .software, sliderFraction: 0.5)
            == VolumeMapping.systemGain(forSliderFraction: 0.5, tier: .software))
        #expect(VolumeFeedback.gain(tier: .software, sliderFraction: 0.0) == 0.0)
        #expect(VolumeFeedback.gain(tier: .software, sliderFraction: 1.0) == 1.0)
    }
}

@Suite("VolumeFeedbackPlayer — cooldown gate")
@MainActor
struct VolumeFeedbackCooldownTests {
    @Test func leadingEdgeGate() {
        let player = VolumeFeedbackPlayer()
        #expect(player.passesCooldown(at: 10.0) == true)
        #expect(player.passesCooldown(at: 10.1) == false)   // inside the 150 ms window
        #expect(player.passesCooldown(at: 10.16) == true)   // window elapsed
        #expect(player.passesCooldown(at: 10.17) == false)  // new window armed by the pass
    }

    @Test func boundaryExactlyAtCooldownPasses() {
        let player = VolumeFeedbackPlayer()
        #expect(player.passesCooldown(at: 0.0) == true)
        #expect(player.passesCooldown(at: VolumeFeedbackPlayer.cooldown) == true)  // exact: 0.15 - 0.0 == cooldown, fails under >
    }
}
