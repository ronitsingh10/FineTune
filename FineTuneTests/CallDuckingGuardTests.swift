// FineTuneTests/CallDuckingGuardTests.swift
// Tests for CallDuckingGuard bookkeeping around the injected duck function.
// No CoreAudio — the private AudioDeviceDuck call is replaced by a recorder.

import Testing
import CoreAudio
@testable import FineTune

@MainActor
@Suite("CallDuckingGuard — duck request bookkeeping")
struct CallDuckingGuardTests {

    /// Records every (device, level) the guard sends and answers with a scripted status.
    @MainActor
    final class Recorder {
        var calls: [(device: AudioDeviceID, level: Float32)] = []
        var statusByDevice: [AudioDeviceID: OSStatus] = [:]

        var function: CallDuckingGuard.DuckFunction {
            { [self] device, level in
                MainActor.assumeIsolated {
                    calls.append((device, level))
                    return statusByDevice[device] ?? noErr
                }
            }
        }
    }

    @Test("hold sends the 0.999 hold level once per device")
    func holdSendsHoldLevelOnce() {
        let recorder = Recorder()
        let guardian = CallDuckingGuard(isEnabled: true, duckFunction: recorder.function)

        guardian.hold(42)
        guardian.hold(42)
        guardian.hold([42, 43])

        #expect(recorder.calls.map(\.device) == [42, 43])
        #expect(recorder.calls.allSatisfy { $0.level == CallDuckingGuard.holdLevel })
        #expect(guardian.heldDeviceIDs == [42, 43])
    }

    @Test("hold level sits just below unity so coreaudiod keeps the request on file")
    func holdLevelIsBelowUnity() {
        #expect(CallDuckingGuard.holdLevel < 1.0)
        #expect(CallDuckingGuard.holdLevel > 0.99)
        #expect(CallDuckingGuard.releaseLevel == 1.0)
    }

    @Test("hold ignores the unknown device ID")
    func holdIgnoresUnknownDevice() {
        let recorder = Recorder()
        let guardian = CallDuckingGuard(isEnabled: true, duckFunction: recorder.function)

        guardian.hold(AudioDeviceID(kAudioObjectUnknown))

        #expect(recorder.calls.isEmpty)
        #expect(guardian.heldDeviceIDs.isEmpty)
    }

    @Test("a failed request is not recorded as held and is retried on the next hold")
    func failedRequestIsRetried() {
        let recorder = Recorder()
        recorder.statusByDevice[7] = OSStatus(kAudioHardwareBadDeviceError)
        let guardian = CallDuckingGuard(isEnabled: true, duckFunction: recorder.function)

        guardian.hold(7)
        #expect(guardian.heldDeviceIDs.isEmpty)

        recorder.statusByDevice[7] = noErr
        guardian.hold(7)

        #expect(recorder.calls.count == 2)
        #expect(guardian.heldDeviceIDs == [7])
    }

    @Test("release sends 1.0 for a held device and nothing for an unheld one")
    func releaseSendsUnityOnlyWhenHeld() {
        let recorder = Recorder()
        let guardian = CallDuckingGuard(isEnabled: true, duckFunction: recorder.function)
        guardian.hold(5)

        guardian.release(5)
        guardian.release(5)
        guardian.release(6)

        #expect(recorder.calls.count == 2)
        #expect(recorder.calls.last?.device == 5)
        #expect(recorder.calls.last?.level == CallDuckingGuard.releaseLevel)
        #expect(guardian.heldDeviceIDs.isEmpty)
    }

    @Test("disabling releases every held device; enabling holds nothing by itself")
    func disablingReleasesEverything() {
        let recorder = Recorder()
        let guardian = CallDuckingGuard(isEnabled: true, duckFunction: recorder.function)
        guardian.hold([1, 2, 3])

        guardian.setEnabled(false)

        let releases = recorder.calls.filter { $0.level == CallDuckingGuard.releaseLevel }
        #expect(Set(releases.map(\.device)) == [1, 2, 3])
        #expect(guardian.heldDeviceIDs.isEmpty)
        #expect(guardian.isEnabled == false)

        let callsBeforeEnable = recorder.calls.count
        guardian.setEnabled(true)
        #expect(recorder.calls.count == callsBeforeEnable)
        #expect(guardian.isEnabled == true)
    }

    @Test("hold is a no-op while disabled")
    func holdIsNoOpWhileDisabled() {
        let recorder = Recorder()
        let guardian = CallDuckingGuard(isEnabled: false, duckFunction: recorder.function)

        guardian.hold([1, 2])

        #expect(recorder.calls.isEmpty)
        #expect(guardian.heldDeviceIDs.isEmpty)
    }

    @Test("retain(only:) forgets disconnected devices without calling the HAL")
    func retainForgetsDisconnectedDevices() {
        let recorder = Recorder()
        let guardian = CallDuckingGuard(isEnabled: true, duckFunction: recorder.function)
        guardian.hold([10, 11, 12])
        let callsAfterHold = recorder.calls.count

        guardian.retain(only: [11])

        #expect(guardian.heldDeviceIDs == [11])
        #expect(recorder.calls.count == callsAfterHold)

        // A reconnected device comes back under a new ID and is held afresh.
        guardian.hold(10)
        #expect(guardian.heldDeviceIDs == [10, 11])
    }

    @Test("an unavailable symbol makes every operation a silent no-op")
    func unavailableSymbolIsNoOp() {
        let guardian = CallDuckingGuard(isEnabled: true, duckFunction: nil)

        guardian.hold([1, 2])
        guardian.release(1)
        guardian.setEnabled(false)

        #expect(guardian.isAvailable == false)
        #expect(guardian.heldDeviceIDs.isEmpty)
    }

    @Test("the production symbol resolves on this macOS")
    func productionSymbolResolves() {
        #expect(CallDuckingGuard.systemDuckFunction != nil)
    }
}
