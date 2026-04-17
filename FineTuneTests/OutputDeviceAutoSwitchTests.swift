import Foundation
import Testing
@testable import FineTune

@Suite("Output auto-switch behavior")
@MainActor
struct OutputDeviceAutoSwitchTests {

    @Test("Lower-priority connected output does not auto-switch when the setting is disabled")
    func lowerPriorityDeviceRespectsPriorityWhenAutoSwitchDisabled() {
        let shouldSwitch = AudioEngine.shouldSwitchToConnectedOutputDevice(
            connectedDeviceUID: "headphones",
            currentDefaultUID: "built-in",
            highestPriorityUID: "built-in",
            autoSwitchToConnectedOutputDevice: false
        )

        #expect(shouldSwitch == false)
    }

    @Test("Connected output auto-switches when the setting is enabled")
    func connectedDeviceAutoSwitchesWhenSettingEnabled() {
        let shouldSwitch = AudioEngine.shouldSwitchToConnectedOutputDevice(
            connectedDeviceUID: "headphones",
            currentDefaultUID: "built-in",
            highestPriorityUID: "built-in",
            autoSwitchToConnectedOutputDevice: true
        )

        #expect(shouldSwitch == true)
    }

    @Test("Highest-priority connected output still auto-switches when the setting is disabled")
    func highestPriorityDeviceStillSwitchesWhenAutoSwitchDisabled() {
        let shouldSwitch = AudioEngine.shouldSwitchToConnectedOutputDevice(
            connectedDeviceUID: "headphones",
            currentDefaultUID: "built-in",
            highestPriorityUID: "headphones",
            autoSwitchToConnectedOutputDevice: false
        )

        #expect(shouldSwitch == true)
    }

    @Test("Pending macOS auto-switch is accepted when connected-output auto-switch is enabled")
    func pendingAutoSwitchAcceptsConnectedDeviceWhenSettingEnabled() {
        let decision = AudioEngine.resolvePendingAutoSwitchDecision(
            newDefaultUID: "headphones",
            pendingConnectedDeviceUID: "headphones",
            autoSwitchToConnectedOutputDevice: true,
            lastAutoSwitchOverrideTime: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(decision == .acceptConnectedDevice)
    }

    @Test("Pending macOS auto-switch restores prior default when the setting is disabled")
    func pendingAutoSwitchRestoresPreviousDefaultWhenSettingDisabled() {
        let decision = AudioEngine.resolvePendingAutoSwitchDecision(
            newDefaultUID: "headphones",
            pendingConnectedDeviceUID: "headphones",
            autoSwitchToConnectedOutputDevice: false,
            lastAutoSwitchOverrideTime: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(decision == .restoreConfirmedDefault)
    }

    @Test("Settled device change is treated as user intent even when the setting is disabled")
    func pendingAutoSwitchAcceptsSettledUserChange() {
        let decision = AudioEngine.resolvePendingAutoSwitchDecision(
            newDefaultUID: "headphones",
            pendingConnectedDeviceUID: "headphones",
            autoSwitchToConnectedOutputDevice: false,
            lastAutoSwitchOverrideTime: Date(timeIntervalSince1970: 98),
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(decision == .acceptConnectedDevice)
    }
}
