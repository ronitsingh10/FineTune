import AppKit
import CoreGraphics
import os

private let kNXSysDefined: UInt32 = 14

private let mediaKeyTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<MediaKeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout {
        if let tap = manager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type.rawValue == kNXSysDefined else {
        return Unmanaged.passRetained(event)
    }

    guard let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passRetained(event)
    }

    let data1 = Int(nsEvent.data1)
    let keyCode = (data1 & 0xFFFF0000) >> 16
    let keyDown = ((data1 & 0xFF00) >> 8) == 0xA

    guard keyDown, keyCode == 0 || keyCode == 1 || keyCode == 7 else {
        return Unmanaged.passRetained(event)
    }

    guard manager.shouldIntercept else {
        return Unmanaged.passRetained(event)
    }

    switch keyCode {
    case 0: manager.onVolumeUp?()
    case 1: manager.onVolumeDown?()
    case 7: manager.onMuteToggle?()
    default: break
    }

    return nil
}

final class MediaKeyManager {
    nonisolated(unsafe) var shouldIntercept: Bool = false
    nonisolated(unsafe) var onVolumeUp: (() -> Void)?
    nonisolated(unsafe) var onVolumeDown: (() -> Void)?
    nonisolated(unsafe) var onMuteToggle: (() -> Void)?

    private(set) var isActive: Bool = false
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var selfPtr: UnsafeMutableRawPointer?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "MediaKeyManager")

    func start() {
        guard eventTap == nil else { return }

        let ptr = Unmanaged.passUnretained(self).toOpaque()

        let eventMask = CGEventMask(1 << kNXSysDefined)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: mediaKeyTapCallback,
            userInfo: ptr
        ) else {
            logger.warning("CGEventTap creation failed — Accessibility permission may not be granted")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        selfPtr = ptr
        isActive = true
        logger.info("Media key tap installed")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        selfPtr = nil
        shouldIntercept = false
        isActive = false
        logger.info("Media key tap removed")
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
