// FineTuneTests/BTCallModeThresholdTests.swift
// Tests for AudioDeviceMonitor.isCallModeTransition(oldRate:newRate:).
// The old threshold (rate <= 16_000) missed AirPods Pro wideband SCO at 24 kHz;
// the fix raises it to rate < 44_100. Tests cover A2DP ↔ SCO transitions, the
// 44.1 kHz boundary, the cold-connect path (oldRate == 0), and the newRate == 0
// HAL-transient sentinel.

import Testing
import Foundation
@testable import FineTune

@Suite("AudioDeviceMonitor — BT call-mode transition detection")
struct BTCallModeThresholdTests {

    // MARK: - A2DP ↔ call-mode transitions

    @Test("A2DP → wideband SCO (48 kHz → 24 kHz) fires: the AirPods Pro bug case")
    func a2dpToWidebandSCO() {
        #expect(AudioDeviceMonitor.isCallModeTransition(oldRate: 48_000, newRate: 24_000))
    }

    @Test("Wideband SCO → A2DP (24 kHz → 48 kHz) fires: call ended")
    func widebandSCOToA2DP() {
        #expect(AudioDeviceMonitor.isCallModeTransition(oldRate: 24_000, newRate: 48_000))
    }

    @Test("44.1 kHz is A2DP, not call-mode: transition to 24 kHz fires")
    func boundaryIsA2DP() {
        #expect(AudioDeviceMonitor.isCallModeTransition(oldRate: 44_100, newRate: 24_000))
    }

    @Test("A2DP quality change (48 kHz → 44.1 kHz) does not fire")
    func a2dpQualityChange() {
        #expect(!AudioDeviceMonitor.isCallModeTransition(oldRate: 48_000, newRate: 44_100))
    }

    @Test("Same-side call-mode rate change (16 kHz mSBC → 24 kHz wideband SCO) does not fire")
    func callModeToCallMode() {
        #expect(!AudioDeviceMonitor.isCallModeTransition(oldRate: 16_000, newRate: 24_000))
    }

    // MARK: - Cold-connect path (oldRate == 0: baseline never read at listener-install time)

    @Test("Cold-connect settling at A2DP (0 → 48 kHz) fires: tap needs ghost clock applied")
    func coldConnectToA2DP() {
        #expect(AudioDeviceMonitor.isCallModeTransition(oldRate: 0, newRate: 48_000))
        #expect(AudioDeviceMonitor.isCallModeTransition(oldRate: 0, newRate: 44_100))
    }

    @Test("Cold-connect settling at SCO (0 → 24 kHz) does not fire: skip until A2DP")
    func coldConnectToSCO() {
        #expect(!AudioDeviceMonitor.isCallModeTransition(oldRate: 0, newRate: 24_000))
        #expect(!AudioDeviceMonitor.isCallModeTransition(oldRate: 0, newRate: 16_000))
    }

    // MARK: - HAL transient sentinel (newRate == 0: device still negotiating)

    @Test("newRate = 0 (HAL mid-negotiation) does not fire from either mode")
    func newRateZeroDoesNotFire() {
        #expect(!AudioDeviceMonitor.isCallModeTransition(oldRate: 48_000, newRate: 0))
        #expect(!AudioDeviceMonitor.isCallModeTransition(oldRate: 24_000, newRate: 0))
        #expect(!AudioDeviceMonitor.isCallModeTransition(oldRate: 0, newRate: 0))
    }
}
