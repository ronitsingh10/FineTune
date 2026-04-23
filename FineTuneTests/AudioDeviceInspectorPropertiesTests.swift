// FineTuneTests/AudioDeviceInspectorPropertiesTests.swift
// Contract tests for AudioDeviceID+Inspector and ProcessNameLookup. Guards
// every CoreAudio-touching test on the existence of a default output device
// so CI runs without audio hardware do not fail.

import Testing
import Foundation
import AudioToolbox
import CoreAudio
@testable import FineTune

// MARK: - Helpers

private func defaultOutputDeviceID() -> AudioDeviceID? {
    var id: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &id
    )
    guard err == noErr, id != kAudioObjectUnknown else { return nil }
    return id
}

// MARK: - AudioDeviceID+Inspector

@Suite("AudioDeviceID Inspector properties")
struct AudioDeviceInspectorPropertiesTests {
    @Test("readAvailableSampleRates returns at least one rate on the default output")
    func availableSampleRates() throws {
        guard let device = defaultOutputDeviceID() else {
            Issue.record("No default output device available; skipping")
            return
        }
        let rates = device.readAvailableSampleRates()
        #expect(!rates.isEmpty)
        for rate in rates {
            #expect(rate > 0)
        }
    }

    @Test("readHogModeOwner returns -1 when no process holds hog mode")
    func hogModeUnowned() throws {
        guard let device = defaultOutputDeviceID() else {
            Issue.record("No default output device available; skipping")
            return
        }
        let owner = device.readHogModeOwner()
        #expect(owner == -1 || owner == getpid())
    }

    @Test("readPhysicalFormat returns an ASBD or nil without crashing")
    func physicalFormat() throws {
        guard let device = defaultOutputDeviceID() else {
            Issue.record("No default output device available; skipping")
            return
        }
        if let asbd = device.readPhysicalFormat() {
            #expect(asbd.mSampleRate > 0)
            #expect(asbd.mChannelsPerFrame >= 1)
        }
    }

    @Test("isPropertySettable returns a boolean without crashing on an unknown selector")
    func settableRobustness() throws {
        guard let device = defaultOutputDeviceID() else {
            Issue.record("No default output device available; skipping")
            return
        }
        let result = device.isPropertySettable(AudioObjectPropertySelector(0x7A7A_7A7A))
        #expect(result == false)
    }

    @Test("isPropertySettable handles a real selector without throwing")
    func settableRealSelector() throws {
        guard let device = defaultOutputDeviceID() else {
            Issue.record("No default output device available; skipping")
            return
        }
        _ = device.isPropertySettable(kAudioDevicePropertyNominalSampleRate)
    }
}

// MARK: - ProcessNameLookup

@Suite("ProcessNameLookup")
struct ProcessNameLookupTests {
    @Test("returns a non-empty name for the current process")
    func currentProcess() {
        let name = ProcessNameLookup.name(for: getpid())
        #expect(name != nil)
        #expect(name?.isEmpty == false)
    }

    @Test("returns nil for PID 0")
    func pidZero() {
        #expect(ProcessNameLookup.name(for: 0) == nil)
    }

    @Test("returns nil for a negative PID")
    func negativePID() {
        #expect(ProcessNameLookup.name(for: -1) == nil)
    }

    @Test("returns nil for an improbably large PID")
    func bogusLargePID() {
        #expect(ProcessNameLookup.name(for: 999_999_999) == nil)
    }
}
