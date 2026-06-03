// FineTuneTests/AggregatePlanTests.swift
//
// Tests ProcessTapController.planAggregate() — the pure planning step that decides which
// hardware sub-devices FineTune's private wrapping aggregate contains and whether it is
// "stacked".
//
// Background (the bug these tests guard against): a user-created aggregate device whose
// stereo speaker is assigned to channels other than 1/2 (e.g. 3/4) was not honoured.
// Two CoreAudio constraints caused it:
//   1. Aggregates can't be nested — wrapping one yields 0 output channels, so user
//      aggregates must be flattened into their hardware sub-devices.
//   2. A stacked aggregate collapses a multichannel sub-device to a single stereo pair,
//      hiding channels 3+ so the preferred-channel placement could never reach them.

import Testing
@testable import FineTune

@Suite("ProcessTapController — Aggregate Planning")
struct AggregatePlanTests {

    /// expand() that knows about one user aggregate ("agg") wrapping two hardware devices.
    private func expand(_ map: [String: [String]]) -> (String) -> [String]? {
        { uid in map[uid] }
    }

    @Test("Single plain device: unchanged, stays stacked")
    func singlePlainDevice() {
        let plan = ProcessTapController.planAggregate(outputUIDs: ["builtin"]) { _ in nil }
        #expect(plan.subDeviceUIDs == ["builtin"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "builtin")
    }

    @Test("Single aggregate: flattened to hardware sub-devices and NOT stacked")
    func singleAggregateFlattened() {
        let plan = ProcessTapController.planAggregate(outputUIDs: ["agg"]) {
            $0 == "agg" ? ["scarlett"] : nil
        }
        #expect(plan.subDeviceUIDs == ["scarlett"])
        // Non-stacked is the crux: it exposes all of the device's channels so the IO
        // callback can place audio on the aggregate's preferred (3/4) channels.
        #expect(plan.isStacked == false)
        #expect(plan.clockDeviceUID == "scarlett")
    }

    @Test("Single aggregate with multiple sub-devices: all flattened, non-stacked, order preserved")
    func singleAggregateMultipleSubDevices() {
        let plan = ProcessTapController.planAggregate(outputUIDs: ["agg"]) {
            $0 == "agg" ? ["devA", "devB"] : nil
        }
        #expect(plan.subDeviceUIDs == ["devA", "devB"])
        #expect(plan.isStacked == false)
        #expect(plan.clockDeviceUID == "devA")
    }

    @Test("Multi-device mirroring: stays stacked, order preserved")
    func multiDeviceMirroring() {
        let plan = ProcessTapController.planAggregate(outputUIDs: ["a", "b"]) { _ in nil }
        #expect(plan.subDeviceUIDs == ["a", "b"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "a")
    }

    @Test("Mirroring that includes an aggregate: aggregate flattened but stays stacked (mirror)")
    func mirroringWithAggregate() {
        let plan = ProcessTapController.planAggregate(outputUIDs: ["agg", "speaker"]) {
            $0 == "agg" ? ["scarlett"] : nil
        }
        #expect(plan.subDeviceUIDs == ["scarlett", "speaker"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "scarlett")
    }

    @Test("Duplicate hardware devices across flattening are de-duplicated, order preserved")
    func deduplicatesSubDevices() {
        let plan = ProcessTapController.planAggregate(outputUIDs: ["agg", "scarlett"]) {
            $0 == "agg" ? ["scarlett", "canton"] : nil
        }
        #expect(plan.subDeviceUIDs == ["scarlett", "canton"])
        // count > 1 user selection ⇒ mirroring ⇒ stacked
        #expect(plan.isStacked == true)
    }

    @Test("Empty aggregate sub-device list is treated as a plain device")
    func emptyAggregateTreatedAsPlain() {
        // expand returning [] means "not flattenable" — keep the original UID.
        let plan = ProcessTapController.planAggregate(outputUIDs: ["agg"]) { _ in [] }
        #expect(plan.subDeviceUIDs == ["agg"])
        #expect(plan.isStacked == true)
    }
}

@Suite("ProcessTapController — IO Proc input stream usage")
struct InputStreamUsageTests {

    @Test("Duplex device (mic + tap): hardware mic stream disabled, tap kept")
    func duplexDisablesMicKeepsTap() {
        // Scarlett-style: input streams = [hardware mic, tap], output streams = [speaker].
        // Only the trailing tap stream should be marked used.
        let flags = ProcessTapController.inputStreamUsageFlags(inputCount: 2, outputCount: 1)
        #expect(flags == [0, 1])
    }

    @Test("Output-only device (tap only): nothing to disable")
    func outputOnlyNoChange() {
        // input streams = [tap], output streams = [speaker] — the tap must stay on, so there is
        // nothing to disable and we return nil (no property write).
        #expect(ProcessTapController.inputStreamUsageFlags(inputCount: 1, outputCount: 1) == nil)
    }

    @Test("Multiple hardware inputs before the tap are all disabled")
    func multipleHardwareInputsDisabled() {
        let flags = ProcessTapController.inputStreamUsageFlags(inputCount: 4, outputCount: 1)
        #expect(flags == [0, 0, 0, 1])
    }

    @Test("Keeps the trailing outputCount input streams when several outputs exist")
    func keepsTrailingByOutputCount() {
        let flags = ProcessTapController.inputStreamUsageFlags(inputCount: 3, outputCount: 2)
        #expect(flags == [0, 1, 1])
    }

    @Test("No input streams: nil")
    func noInputs() {
        #expect(ProcessTapController.inputStreamUsageFlags(inputCount: 0, outputCount: 1) == nil)
    }
}
