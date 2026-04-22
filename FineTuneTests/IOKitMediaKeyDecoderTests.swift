// FineTuneTests/IOKitMediaKeyDecoderTests.swift
// Tests for IOKitMediaKeyDecoder using inline HID data1 fixtures.
//
// HID bitfield layout (<IOKit/hidsystem/ev_keymap.h>):
//   keyType  = (data1 & 0xFFFF0000) >> 16
//   keyFlags = (data1 & 0x0000FFFF)
//   isDown   = ((keyFlags & 0xFF00) >> 8) == 0x0A
//   isRepeat = (keyFlags & 0xFF) != 0
//
// Fixtures (all values decimal):
//   SOUND_UP   (keyType=0): down=2560, repeat=2561, up=2816
//   SOUND_DOWN (keyType=1): down=68096, repeat=68097, up=68352
//   MUTE       (keyType=7): down=460288, repeat=460289, up=460544
//   BRIGHTNESS (keyType=2, unknown): down=134656

import Testing
@testable import FineTune

@Suite("IOKitMediaKeyDecoder — HID bitfield decoding")
struct IOKitMediaKeyDecoderTests {
    let decoder = IOKitMediaKeyDecoder()

    // MARK: - Volume Up

    @Test("SOUND_UP key-down (data1=2560) decodes to volumeUp(isRepeat:false)")
    func soundUpDown() {
        let result = decoder.decode(data1: 0x00000A00)  // 2560
        #expect(result == .volumeUp(isRepeat: false))
    }

    @Test("SOUND_UP auto-repeat (data1=2561) decodes to volumeUp(isRepeat:true)")
    func soundUpRepeat() {
        let result = decoder.decode(data1: 0x00000A01)  // 2561
        #expect(result == .volumeUp(isRepeat: true))
    }

    @Test("SOUND_UP key-up (data1=2816) decodes to nil (not a key-down)")
    func soundUpKeyUp() {
        let result = decoder.decode(data1: 0x00000B00)  // 2816
        #expect(result == nil)
    }

    // MARK: - Volume Down

    @Test("SOUND_DOWN key-down (data1=68096) decodes to volumeDown(isRepeat:false)")
    func soundDownDown() {
        let result = decoder.decode(data1: 0x00010A00)  // 68096
        #expect(result == .volumeDown(isRepeat: false))
    }

    @Test("SOUND_DOWN auto-repeat (data1=68097) decodes to volumeDown(isRepeat:true)")
    func soundDownRepeat() {
        let result = decoder.decode(data1: 0x00010A01)  // 68097
        #expect(result == .volumeDown(isRepeat: true))
    }

    @Test("SOUND_DOWN key-up (data1=68352) decodes to nil")
    func soundDownKeyUp() {
        let result = decoder.decode(data1: 0x00010B00)  // 68352
        #expect(result == nil)
    }

    // MARK: - Mute

    @Test("MUTE key-down (data1=460288) decodes to muteToggle")
    func muteDown() {
        let result = decoder.decode(data1: 0x00070A00)  // 460288
        #expect(result == .muteToggle)
    }

    @Test("MUTE auto-repeat (data1=460289) decodes to nil (mute ignores repeat)")
    func muteRepeat() {
        let result = decoder.decode(data1: 0x00070A01)  // 460289
        #expect(result == nil)
    }

    @Test("MUTE key-up (data1=460544) decodes to nil")
    func muteKeyUp() {
        let result = decoder.decode(data1: 0x00070B00)  // 460544
        #expect(result == nil)
    }

    // MARK: - Unknown key type

    @Test("Unknown keyType (BRIGHTNESS, keyType=2, data1=134656) decodes to nil (fail-open)")
    func unknownKeyTypeFailOpen() {
        let result = decoder.decode(data1: 0x00020A00)  // 134656
        #expect(result == nil)
    }

    // MARK: - MediaKeyEvent Equatable

    @Test("MediaKeyEvent.volumeUp(isRepeat:false) equals itself")
    func volumeUpEquatable() {
        #expect(MediaKeyEvent.volumeUp(isRepeat: false) == .volumeUp(isRepeat: false))
        #expect(MediaKeyEvent.volumeUp(isRepeat: false) != .volumeUp(isRepeat: true))
    }

    @Test("MediaKeyEvent.volumeDown and volumeUp are not equal")
    func differentEventsNotEqual() {
        #expect(MediaKeyEvent.volumeDown(isRepeat: false) != .volumeUp(isRepeat: false))
    }
}
