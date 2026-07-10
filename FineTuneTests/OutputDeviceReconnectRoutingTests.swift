// FineTuneTests/OutputDeviceReconnectRoutingTests.swift
import Testing
import Foundation
@testable import FineTune

/// Regression coverage for the Bluetooth-reconnect routing desync:
/// when a headset reconnects and macOS auto-switches the system default to it,
/// the highest-priority connected device must be ensured as the default so
/// follows-default app taps are re-routed to it — not left stranded on the
/// previous device.
@Suite("Connected output default action")
@MainActor
struct OutputDeviceReconnectRoutingTests {

    // The bug: headset is highest connected priority AND macOS already made it the
    // default. The old code did nothing here, leaving app taps on the old device.
    @Test("Highest-priority device already made default by macOS → ensure default + re-route apps")
    func highestPriorityAlreadyDefault() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "buds",
            highestPriorityConnectedUID: "buds",
            currentDefaultUID: "buds"
        )
        #expect(action == .ensureHighestPriorityDefault)
    }

    @Test("Highest-priority device reconnects while default is still the old device → ensure default")
    func highestPriorityNotYetDefault() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "buds",
            highestPriorityConnectedUID: "buds",
            currentDefaultUID: "speakers"
        )
        #expect(action == .ensureHighestPriorityDefault)
    }

    @Test("Highest-priority device connects with no default set yet (nil) → ensure default")
    func highestPriorityWithNoCurrentDefault() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "buds",
            highestPriorityConnectedUID: "buds",
            currentDefaultUID: nil
        )
        #expect(action == .ensureHighestPriorityDefault)
    }

    // The user's real setup: WH-1000XM5 is #1 in the priority list but disconnected,
    // Buds4 (#2) and built-in speakers (#3) are connected. The disconnected #1 must be
    // skipped so the highest *connected* device (the Buds) is what reconnect logic acts on.
    @Test("resolveHighestPriority skips a disconnected #1 and returns the highest connected device")
    func highestPrioritySkipsDisconnectedTopDevice() {
        let buds = AudioDevice(id: 2, uid: "buds", name: "Buds4 Pro", icon: nil, supportsAutoEQ: false)
        let speakers = AudioDevice(id: 3, uid: "speakers", name: "MacBook Pro Speakers", icon: nil, supportsAutoEQ: false)

        // wh1000xm5 (#1) is disconnected → absent from the connected set entirely.
        let resolved = AudioEngine.resolveHighestPriority(
            priorityOrder: ["wh1000xm5", "buds", "speakers"],
            connectedDevices: [buds, speakers],
            isAlive: { _ in true }
        )
        #expect(resolved?.uid == "buds")

        // …and that resolved device, once macOS makes it default, must be ensured.
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "buds",
            highestPriorityConnectedUID: resolved?.uid,
            currentDefaultUID: "buds"
        )
        #expect(action == .ensureHighestPriorityDefault)
    }

    // Protection behaviour must be preserved: a *lower*-priority device that macOS
    // hijacked the default to should be reverted to the device the user was on.
    @Test("Lower-priority device that macOS auto-switched to → restore previous")
    func lowerPriorityHijackRestores() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "airpods",
            highestPriorityConnectedUID: "wh1000xm5",
            currentDefaultUID: "airpods"
        )
        #expect(action == .restorePrevious)
    }

    @Test("Lower-priority device connects but default unchanged → do nothing")
    func lowerPriorityNonDefaultIsNoop() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "airpods",
            highestPriorityConnectedUID: "wh1000xm5",
            currentDefaultUID: "wh1000xm5"
        )
        #expect(action == .none)
    }

    @Test("No connected devices resolved (nil highest) and not default → do nothing")
    func nilHighestNonDefaultIsNoop() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "buds",
            highestPriorityConnectedUID: nil,
            currentDefaultUID: "speakers"
        )
        #expect(action == .none)
    }

    // Defensive: a live connected device normally makes resolveHighestPriority non-nil
    // (its fallback returns any alive device), so nil-highest-while-default shouldn't occur
    // in practice — but pin the behaviour so a future refactor can't silently change it.
    @Test("Nil highest but device is current default → restore previous")
    func nilHighestButIsDefaultRestores() {
        let action = AudioEngine.connectedOutputDefaultAction(
            connectedDeviceUID: "buds",
            highestPriorityConnectedUID: nil,
            currentDefaultUID: "buds"
        )
        #expect(action == .restorePrevious)
    }
}
