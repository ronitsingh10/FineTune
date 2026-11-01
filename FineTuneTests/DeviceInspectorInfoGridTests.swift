// FineTuneTests/DeviceInspectorInfoGridTests.swift
//
// Structural tests for `InfoGridLayout` — the pure layout function behind
// the Device Inspector info grid. Asserts on the ordered row output, not
// on SwiftUI view trees (no ViewInspector dependency).

import Testing
import Foundation
import AudioToolbox
import CoreAudio
@testable import FineTune

// MARK: - Formatter tests

@Suite("DeviceInspectorInfo — formatters")
struct DeviceInspectorFormatterTests {
    @Test("formatSampleRate renders integer kHz without a decimal")
    func integerSampleRate() {
        #expect(DeviceInspectorInfo.formatSampleRate(48_000) == "48 kHz")
        #expect(DeviceInspectorInfo.formatSampleRate(96_000) == "96 kHz")
    }

    @Test("formatSampleRate renders 44.1 kHz with one decimal")
    func fractionalSampleRate() {
        #expect(DeviceInspectorInfo.formatSampleRate(44_100) == "44.1 kHz")
        #expect(DeviceInspectorInfo.formatSampleRate(88_200) == "88.2 kHz")
    }

    @Test("formatSampleRate renders zero/negative as em-less dash")
    func zeroSampleRate() {
        #expect(DeviceInspectorInfo.formatSampleRate(0) == "—")
        #expect(DeviceInspectorInfo.formatSampleRate(-1) == "—")
    }

    @Test("formatPhysicalFormat renders bit-depth for LPCM")
    func lpcmFormat() {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mBitsPerChannel = 24
        #expect(DeviceInspectorInfo.formatPhysicalFormat(asbd) == "24-bit PCM")
    }

    @Test("formatPhysicalFormat returns nil for non-LPCM streams")
    func nonLPCMFormat() {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatAC3
        asbd.mBitsPerChannel = 0
        #expect(DeviceInspectorInfo.formatPhysicalFormat(asbd) == nil)
    }

    @Test("formatPhysicalFormat returns nil when bit depth is zero (Bluetooth case)")
    func zeroBitsPerChannel() {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mBitsPerChannel = 0
        #expect(DeviceInspectorInfo.formatPhysicalFormat(asbd) == nil)
    }

    @Test("formatPhysicalFormat returns nil for nil input")
    func nilAsbd() {
        #expect(DeviceInspectorInfo.formatPhysicalFormat(nil) == nil)
    }

    @Test("formatHogModeOwner returns nil when owner is -1")
    func hogUnowned() {
        #expect(DeviceInspectorInfo.formatHogModeOwner(-1, processName: nil) == nil)
    }

    @Test("formatHogModeOwner returns nil when self-owned")
    func hogSelfOwned() {
        #expect(DeviceInspectorInfo.formatHogModeOwner(getpid(), processName: "FineTune") == nil)
    }

    @Test("formatHogModeOwner returns resolved name when provided")
    func hogWithName() {
        let result = DeviceInspectorInfo.formatHogModeOwner(
            1234,
            processName: "Audirvana",
            locale: Locale(identifier: "en")
        )
        #expect(result == "In exclusive use by Audirvana (PID 1234)")
    }

    @Test("formatHogModeOwner falls back to PID-only when name is nil")
    func hogWithoutName() {
        let result = DeviceInspectorInfo.formatHogModeOwner(
            5678,
            processName: nil,
            locale: Locale(identifier: "en")
        )
        #expect(result == "In exclusive use by PID 5678")
    }

    @Test("formatHogModeOwner falls back to PID-only when name is empty")
    func hogWithEmptyName() {
        let result = DeviceInspectorInfo.formatHogModeOwner(
            5678,
            processName: "",
            locale: Locale(identifier: "en")
        )
        #expect(result == "In exclusive use by PID 5678")
    }
}

// MARK: - Layout tests

@Suite("InfoGridLayout — row decisions")
struct InfoGridLayoutTests {
    private func makeInfo(
        sampleRate: Double = 48_000,
        availableSampleRates: [Double] = [48_000],
        sampleRateSettable: Bool = false,
        formatLabel: String? = nil,
        hogModeOwner: pid_t = -1,
        uid: String = "uid-test"
    ) -> DeviceInspectorInfo {
        DeviceInspectorInfo(
            transportLabel: "USB",
            sampleRate: sampleRate,
            availableSampleRates: availableSampleRates,
            sampleRateSettable: sampleRateSettable,
            formatLabel: formatLabel,
            hogModeOwner: hogModeOwner,
            uid: uid
        )
    }

    @Test("Always emits Transport as the first row")
    func transportAlwaysFirst() {
        let layout = InfoGridLayout(info: makeInfo())
        #expect(layout.rows.first == .transport("USB"))
    }

    @Test("Always emits a sample-rate row")
    func sampleRateAlwaysPresent() {
        let layout = InfoGridLayout(info: makeInfo())
        let hasSampleRate = layout.rows.contains { row in
            if case .sampleRate = row { return true }
            return false
        }
        #expect(hasSampleRate)
    }

    @Test("Sample-rate row is a picker when settable AND options > 1")
    func pickerWhenSettable() {
        let info = makeInfo(
            availableSampleRates: [44_100, 48_000, 96_000],
            sampleRateSettable: true
        )
        let layout = InfoGridLayout(info: info)
        guard case .sampleRate(_, let isPicker, let options) = layout.rows[1] else {
            Issue.record("Expected sampleRate row at index 1")
            return
        }
        #expect(isPicker)
        #expect(options == [44_100, 48_000, 96_000])
    }

    @Test("Sample-rate row is plain text when not settable")
    func plainTextWhenNotSettable() {
        let info = makeInfo(
            availableSampleRates: [44_100, 48_000, 96_000],
            sampleRateSettable: false
        )
        let layout = InfoGridLayout(info: info)
        guard case .sampleRate(_, let isPicker, let options) = layout.rows[1] else {
            Issue.record("Expected sampleRate row at index 1")
            return
        }
        #expect(!isPicker)
        #expect(options.isEmpty)
    }

    @Test("Sample-rate row is plain text when only one rate is available")
    func plainTextWhenSingleRate() {
        let info = makeInfo(
            availableSampleRates: [48_000],
            sampleRateSettable: true
        )
        let layout = InfoGridLayout(info: info)
        guard case .sampleRate(_, let isPicker, _) = layout.rows[1] else {
            Issue.record("Expected sampleRate row at index 1")
            return
        }
        #expect(!isPicker)
    }

    @Test("Format row hidden when formatLabel is nil")
    func formatHiddenWhenNil() {
        let layout = InfoGridLayout(info: makeInfo(formatLabel: nil))
        let hasFormat = layout.rows.contains { row in
            if case .format = row { return true }
            return false
        }
        #expect(!hasFormat)
    }

    @Test("Device ID row is always emitted as the last row")
    func deviceIDAlwaysLast() {
        let withFormat = InfoGridLayout(info: makeInfo(formatLabel: "24-bit PCM", uid: "abc-123"))
        #expect(withFormat.rows.last == .deviceID("abc-123"))

        let withoutFormat = InfoGridLayout(info: makeInfo(formatLabel: nil, uid: "def-456"))
        #expect(withoutFormat.rows.last == .deviceID("def-456"))
    }

    @Test("Format row sits between Sample rate and Device ID when present")
    func formatRowPosition() {
        let layout = InfoGridLayout(info: makeInfo(formatLabel: "24-bit PCM"))
        guard layout.rows.count >= 3 else {
            Issue.record("Expected at least 3 rows")
            return
        }
        if case .format("24-bit PCM") = layout.rows[2] {} else {
            Issue.record("Row 2 should be format(24-bit PCM)")
        }
    }

    @Test("Row order is Transport → Sample rate → Format → Device ID")
    func rowOrder() {
        let layout = InfoGridLayout(info: makeInfo(formatLabel: "16-bit PCM", uid: "uid-xyz"))
        guard layout.rows.count == 4 else {
            Issue.record("Expected 4 rows, got \(layout.rows.count)")
            return
        }
        if case .transport = layout.rows[0] {} else { Issue.record("Row 0 should be transport") }
        if case .sampleRate = layout.rows[1] {} else { Issue.record("Row 1 should be sampleRate") }
        if case .format = layout.rows[2] {} else { Issue.record("Row 2 should be format") }
        if case .deviceID = layout.rows[3] {} else { Issue.record("Row 3 should be deviceID") }
    }

    @Test("Layout is 3 rows when format is absent (Transport, Sample rate, Device ID)")
    func threeRowsWithoutFormat() {
        let layout = InfoGridLayout(info: makeInfo(formatLabel: nil))
        #expect(layout.rows.count == 3)
    }
}
