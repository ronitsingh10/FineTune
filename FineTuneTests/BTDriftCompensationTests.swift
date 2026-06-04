// FineTuneTests/BTDriftCompensationTests.swift
// Tests for ProcessTapController.aggregateDriftCompEnabled(...).
// The missing !isPrimaryBTOutput guard caused the HAL to insert/delete one sample
// every ~0.7 s on BT call-mode aggregates (50 ppm BT-vs-crystal offset).

import Testing
import Foundation
@testable import FineTune

@Suite("ProcessTapController — aggregate drift comp decision")
struct BTDriftCompensationTests {

    @Test("BT primary output, no ghost clock → disabled (BT is clock master; shared domain)")
    func btPrimaryDisablesDriftComp() {
        #expect(!ProcessTapController.aggregateDriftCompEnabled(
            ghostClockUID: nil,
            isTapSourceVirtual: false,
            isPrimaryBTOutput: true
        ))
    }

    @Test("Non-BT output, no ghost clock → enabled (different clock domains, drift comp needed)")
    func nonBTEnablesDriftComp() {
        #expect(ProcessTapController.aggregateDriftCompEnabled(
            ghostClockUID: nil,
            isTapSourceVirtual: false,
            isPrimaryBTOutput: false
        ))
    }

    @Test("Ghost clock present → disabled regardless of output type")
    func ghostClockDisablesDriftComp() {
        #expect(!ProcessTapController.aggregateDriftCompEnabled(
            ghostClockUID: "BuiltIn_Output",
            isTapSourceVirtual: false,
            isPrimaryBTOutput: false
        ))
    }

    @Test("Virtual source → disabled (burst delivery misread as drift)")
    func virtualSourceDisablesDriftComp() {
        #expect(!ProcessTapController.aggregateDriftCompEnabled(
            ghostClockUID: nil,
            isTapSourceVirtual: true,
            isPrimaryBTOutput: false
        ))
    }
}
