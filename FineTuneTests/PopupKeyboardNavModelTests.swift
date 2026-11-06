// FineTuneTests/PopupKeyboardNavModelTests.swift
import Testing
import AppKit
import AudioToolbox
@testable import FineTune

@MainActor
private func makeDevice(uid: String, id: AudioDeviceID = 1) -> AudioDevice {
    AudioDevice(id: id, uid: uid, name: "Device \(uid)", icon: nil, supportsAutoEQ: false)
}

@Suite("PopupKeyboardNavModel") @MainActor
struct PopupKeyboardNavModelTests {
    @Test func syncOrderProducesDevicesThenApps() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1", id: 1)
        let dev2 = makeDevice(uid: "dev2", id: 2)
        model.syncOrder(
            activeDevices: [dev1, dev2],
            appRowIDs: ["com.test.a", "com.test.b", "com.test.c"],
            isEditingPriority: false
        )
        #expect(model.orderedRowIDs == [
            .device(uid: "dev1"),
            .device(uid: "dev2"),
            .app(rowID: "com.test.a"),
            .app(rowID: "com.test.b"),
            .app(rowID: "com.test.c"),
        ])
    }

    @Test func syncOrderEditingPriorityClearsList() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1")
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: ["com.test.a"],
            isEditingPriority: true
        )
        #expect(model.orderedRowIDs.isEmpty)
    }

    @Test func nextAfterNilReturnsFirstRow() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1")
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: ["com.test.a"],
            isEditingPriority: false
        )
        #expect(model.next(after: nil) == .device(uid: "dev1"))
    }

    @Test func nextAfterNilOnEmptyReturnsNil() {
        let model = PopupKeyboardNavModel()
        #expect(model.next(after: nil) == nil)
    }

    @Test func nextAfterLastReturnsNilNoWrap() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1")
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: ["com.test.a"],
            isEditingPriority: false
        )
        #expect(model.next(after: .app(rowID: "com.test.a")) == nil)
    }

    @Test func nextAfterFirstDeviceReturnsSecondDevice() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1", id: 1)
        let dev2 = makeDevice(uid: "dev2", id: 2)
        model.syncOrder(
            activeDevices: [dev1, dev2],
            appRowIDs: ["com.test.a"],
            isEditingPriority: false
        )
        #expect(model.next(after: .device(uid: "dev1")) == .device(uid: "dev2"))
    }

    @Test func nextAfterLastDeviceCrossesIntoApps() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1", id: 1)
        let dev2 = makeDevice(uid: "dev2", id: 2)
        model.syncOrder(
            activeDevices: [dev1, dev2],
            appRowIDs: ["com.test.a"],
            isEditingPriority: false
        )
        #expect(model.next(after: .device(uid: "dev2")) == .app(rowID: "com.test.a"))
    }

    @Test func previousBeforeNilReturnsNil() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1")
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: [],
            isEditingPriority: false
        )
        #expect(model.previous(before: nil) == nil)
    }

    @Test func previousBeforeFirstRowReturnsNil() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1")
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: ["com.test.a"],
            isEditingPriority: false
        )
        #expect(model.previous(before: .device(uid: "dev1")) == nil)
    }

    @Test func previousBeforeFirstAppCrossesBackIntoDevices() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1")
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: ["com.test.a", "com.test.b"],
            isEditingPriority: false
        )
        #expect(model.previous(before: .app(rowID: "com.test.a")) == .device(uid: "dev1"))
    }

    @Test func defaultFocusPrefersDefaultOutputDevice() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1", id: 1)
        let dev2 = makeDevice(uid: "dev2", id: 2)
        model.syncOrder(
            activeDevices: [dev1, dev2],
            appRowIDs: [],
            isEditingPriority: false
        )
        #expect(model.defaultFocus(defaultOutputUID: "dev2") == .device(uid: "dev2"))
    }

    @Test func defaultFocusNilUIDReturnsFirstRow() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1", id: 1)
        let dev2 = makeDevice(uid: "dev2", id: 2)
        model.syncOrder(
            activeDevices: [dev1, dev2],
            appRowIDs: [],
            isEditingPriority: false
        )
        #expect(model.defaultFocus(defaultOutputUID: nil) == .device(uid: "dev1"))
    }

    @Test func defaultFocusUnknownUIDFallsBackToFirstRow() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1", id: 1)
        let dev2 = makeDevice(uid: "dev2", id: 2)
        model.syncOrder(
            activeDevices: [dev1, dev2],
            appRowIDs: [],
            isEditingPriority: false
        )
        #expect(model.defaultFocus(defaultOutputUID: "unknown-uid") == .device(uid: "dev1"))
    }

    @Test func defaultFocusOnEmptyReturnsNil() {
        let model = PopupKeyboardNavModel()
        #expect(model.defaultFocus(defaultOutputUID: "dev1") == nil)
    }

    @Test func syncOrderDropsExitedApps() {
        let model = PopupKeyboardNavModel()
        let dev1 = makeDevice(uid: "dev1")
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: ["com.test.a"],
            isEditingPriority: false
        )
        model.syncOrder(
            activeDevices: [dev1],
            appRowIDs: [],
            isEditingPriority: false
        )
        #expect(!model.orderedRowIDs.contains(.app(rowID: "com.test.a")))
    }
}
