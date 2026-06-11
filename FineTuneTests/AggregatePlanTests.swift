// FineTuneTests/AggregatePlanTests.swift
//
// Tests ProcessTapController.planAggregate() — the pure planning step that decides which
// hardware sub-devices FineTune's private wrapping aggregate contains and whether it is
// "stacked".
//
// Background (the bug these tests guard against): a user-created aggregate device whose
// stereo speaker is assigned to channels other than 1/2 (e.g. 3/4) was not honoured.
// Three CoreAudio constraints shape the plan:
//   1. Aggregates can't be nested — wrapping one yields 0 output channels, so user
//      aggregates must be flattened into their hardware sub-devices.
//   2. A stacked aggregate collapses a multichannel sub-device to a single stereo pair,
//      hiding channels 3+ so the preferred-channel placement could never reach them.
//   3. The IO callback can only place audio on preferred channels when the wrapper
//      exposes exactly one output stream, so multi-sub-device and multi-stream
//      flattens stay stacked.

import Testing
@testable import FineTune

@Suite("ProcessTapController — Aggregate Planning")
struct AggregatePlanTests {

    @Test("Single plain device: unchanged, stays stacked")
    func singlePlainDevice() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["builtin"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["builtin"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "builtin")
    }

    @Test("Single aggregate around a single-stream device: flattened and NOT stacked")
    func singleAggregateFlattened() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg"],
            expand: { $0 == "agg" ? ["scarlett"] : nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["scarlett"])
        // Non-stacked is the crux: it exposes all of the device's channels so the IO
        // callback can place audio on the aggregate's preferred (3/4) channels.
        #expect(plan.isStacked == false)
        #expect(plan.clockDeviceUID == "scarlett")
    }

    @Test("Single aggregate around a multi-stream device: stays stacked")
    func singleAggregateMultiStreamDevice() {
        // A device exposing several output streams (stream-per-pair interfaces) breaks the
        // callback's single-stream assumptions — the plan must fall back to stacked.
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg"],
            expand: { $0 == "agg" ? ["motu"] : nil },
            outputStreamCount: { _ in 2 }
        )
        #expect(plan.subDeviceUIDs == ["motu"])
        #expect(plan.isStacked == true)
    }

    @Test("Single aggregate with multiple sub-devices: flattened, stays stacked, order preserved")
    func singleAggregateMultipleSubDevices() {
        // Multiple sub-devices ⇒ one output stream per sub-device ⇒ the callback cannot
        // honour global preferred-channel placement, so the wrapper stays stacked
        // (mirrors to all sub-devices, which also makes Multi-Output Devices work).
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg"],
            expand: { $0 == "agg" ? ["devA", "devB"] : nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["devA", "devB"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "devA")
    }

    @Test("Multi-device mirroring: stays stacked, order preserved")
    func multiDeviceMirroring() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["a", "b"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["a", "b"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "a")
    }

    @Test("Mirroring that includes an aggregate: aggregate flattened but stays stacked (mirror)")
    func mirroringWithAggregate() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg", "speaker"],
            expand: { $0 == "agg" ? ["scarlett"] : nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["scarlett", "speaker"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "scarlett")
    }

    @Test("Duplicate hardware devices across flattening are de-duplicated, order preserved")
    func deduplicatesSubDevices() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg", "scarlett"],
            expand: { $0 == "agg" ? ["scarlett", "canton"] : nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["scarlett", "canton"])
        // count > 1 user selection ⇒ mirroring ⇒ stacked
        #expect(plan.isStacked == true)
    }

    @Test("Empty aggregate sub-device list is treated as a plain device")
    func emptyAggregateTreatedAsPlain() {
        // expand returning [] means "not flattenable" — keep the original UID.
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg"],
            expand: { _ in [] },
            outputStreamCount: { _ in 1 }
        )
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

    @Test("Zero output streams (or a failed stream-count read): nil, never an all-unused map")
    func zeroOutputCountNeverDisablesTap() {
        // streamCount() returns 0 when the property read fails; an all-zero map would
        // mark the tap stream itself unused and silence the app permanently.
        #expect(ProcessTapController.inputStreamUsageFlags(inputCount: 2, outputCount: 0) == nil)
    }
}
