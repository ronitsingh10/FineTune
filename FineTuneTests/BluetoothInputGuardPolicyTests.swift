// FineTuneTests/BluetoothInputGuardPolicyTests.swift
//
// Tests BluetoothInputGuardPolicy — the selection rules behind the optional
// Bluetooth input guard. The guard keeps the default input on the built-in mic
// so AirPods stay on the A2DP link instead of falling back to HFP/SCO.

import Testing
@testable import FineTune

@Suite("BluetoothInputGuardPolicy")
struct BluetoothInputGuardPolicyTests {

    private func candidate(_ uid: String, builtIn: Bool, bluetooth: Bool) -> BluetoothInputGuardPolicy.Candidate {
        BluetoothInputGuardPolicy.Candidate(uid: uid, builtIn: builtIn, bluetooth: bluetooth)
    }

    @Test("Prefers the built-in microphone over every other input")
    func prefersBuiltIn() {
        let devices = [
            candidate("usb-mic", builtIn: false, bluetooth: false),
            candidate("airpods", builtIn: false, bluetooth: true),
            candidate("builtin", builtIn: true, bluetooth: false),
        ]
        #expect(BluetoothInputGuardPolicy.target(in: devices) == "builtin")
    }

    @Test("A Bluetooth device is never chosen, even when it reports itself as built-in")
    func skipsBluetooth() {
        let devices = [
            candidate("headset", builtIn: true, bluetooth: true),
            candidate("usb-mic", builtIn: false, bluetooth: false),
        ]
        #expect(BluetoothInputGuardPolicy.target(in: devices) == nil)
    }

    @Test("No built-in mic means no target, so the guard leaves the input alone")
    func noBuiltIn() {
        let devices = [candidate("usb-mic", builtIn: false, bluetooth: false)]
        #expect(BluetoothInputGuardPolicy.target(in: devices) == nil)
    }

    @Test("Input selection is unrestricted while the guard is off")
    func disabledAllowsEverything() {
        let airpods = candidate("airpods", builtIn: false, bluetooth: true)
        #expect(BluetoothInputGuardPolicy.allowsInput(airpods, enabled: false))
    }

    @Test("Only built-in, non-Bluetooth inputs are selectable while the guard is on")
    func enabledRestrictsInputs() {
        #expect(BluetoothInputGuardPolicy.allowsInput(candidate("builtin", builtIn: true, bluetooth: false), enabled: true))
        #expect(!BluetoothInputGuardPolicy.allowsInput(candidate("airpods", builtIn: false, bluetooth: true), enabled: true))
        #expect(!BluetoothInputGuardPolicy.allowsInput(candidate("usb-mic", builtIn: false, bluetooth: false), enabled: true))
    }

    @Test("A2DP output rates are not flagged as call mode")
    func a2dpRateIsNotCallMode() {
        #expect(!BluetoothInputGuardPolicy.suggestsCallMode(sampleRate: 44_100))
        #expect(!BluetoothInputGuardPolicy.suggestsCallMode(sampleRate: 48_000))
    }

    @Test("SCO call-mode rates are flagged")
    func scoRatesAreCallMode() {
        #expect(BluetoothInputGuardPolicy.suggestsCallMode(sampleRate: 8_000))
        #expect(BluetoothInputGuardPolicy.suggestsCallMode(sampleRate: 16_000))
        #expect(BluetoothInputGuardPolicy.suggestsCallMode(sampleRate: 24_000))
    }

    @Test("An unavailable sample rate (0) is not treated as call mode")
    func zeroRateIsUnknown() {
        #expect(!BluetoothInputGuardPolicy.suggestsCallMode(sampleRate: 0))
    }
}
