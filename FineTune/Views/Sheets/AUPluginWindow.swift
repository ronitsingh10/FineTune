// FineTune/Views/Sheets/AUPluginWindow.swift
import AppKit
import AudioToolbox
import CoreAudioKit
import os

@MainActor
final class AUPluginWindowManager {
    static let shared = AUPluginWindowManager()

    private var windows: [UUID: NSWindow] = [:]
    private var saveCallbacks: [UUID: () -> Void] = [:]
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUPluginWindow")

    func showWindow(for entryID: UUID, audioUnit: AudioUnit, pluginName: String, forceGeneric: Bool = false, onSave: @escaping () -> Void) {
        if let existing = windows[entryID] {
            existing.orderFrontRegardless()
            return
        }

        let contentView = forceGeneric ? loadGenericView(for: audioUnit) : (loadCustomView(for: audioUnit) ?? loadGenericView(for: audioUnit))

        let viewSize = contentView.fittingSize
        let width = max(viewSize.width, 400)
        let height = max(viewSize.height, 300)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = pluginName
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = WindowDelegate(entryID: entryID, manager: self)
        window.orderFrontRegardless()

        windows[entryID] = window
        saveCallbacks[entryID] = onSave
        logger.info("Opened AU window for \(pluginName)")
    }

    func closeWindow(for entryID: UUID) {
        windows[entryID]?.close()
        windows.removeValue(forKey: entryID)
    }

    func closeAllWindows() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
    }

    func saveAllOpenWindows() {
        for (_, callback) in saveCallbacks {
            callback()
        }
    }

    fileprivate func windowDidClose(entryID: UUID) {
        saveCallbacks[entryID]?()
        saveCallbacks.removeValue(forKey: entryID)
        windows.removeValue(forKey: entryID)
    }

    // MARK: - View Loading

    private func loadCustomView(for audioUnit: AudioUnit) -> NSView? {
        // Query kAudioUnitProperty_CocoaUI — returns a struct with a bundle URL
        // and an array of class name strings. We only use the first class.
        var dataSize: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoErr = AudioUnitGetPropertyInfo(
            audioUnit,
            kAudioUnitProperty_CocoaUI,
            kAudioUnitScope_Global, 0,
            &dataSize,
            &writable
        )
        guard infoErr == noErr, dataSize > 0 else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { buffer.deallocate() }

        var actualSize = dataSize
        let getErr = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_CocoaUI,
            kAudioUnitScope_Global, 0,
            buffer,
            &actualSize
        )
        guard getErr == noErr else { return nil }

        let viewInfo = buffer.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee

        let bundleURL = viewInfo.mCocoaAUViewBundleLocation.takeRetainedValue() as URL

        let classNameRef: Unmanaged<CFString> = viewInfo.mCocoaAUViewClass
        let className = classNameRef.takeRetainedValue() as String

        guard let bundle = Bundle(url: bundleURL), bundle.load() else {
            logger.warning("Failed to load AU view bundle at \(bundleURL.path)")
            return nil
        }

        // The class must implement the informal AUCocoaUIBase protocol:
        //   - (NSView *)uiViewForAudioUnit:(AudioUnit)au withSize:(NSSize)size
        guard let viewClass = bundle.classNamed(className) as? NSObject.Type else {
            logger.warning("Class \(className) not found in bundle")
            return nil
        }

        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard viewClass.instancesRespond(to: selector) else {
            logger.warning("\(className) does not implement uiViewForAudioUnit:withSize:")
            return nil
        }

        let factory = viewClass.init()
        let size = NSSize(width: 400, height: 300)

        // Call via IMP with correct C types — NSObject.perform() would corrupt
        // the AudioUnit pointer (OpaquePointer, not AnyObject).
        typealias AUViewFactoryIMP = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> NSView?
        guard let method = class_getInstanceMethod(viewClass, selector) else {
            logger.warning("Failed to get method for \(selector)")
            return nil
        }
        let imp = method_getImplementation(method)
        let factoryFunc = unsafeBitCast(imp, to: AUViewFactoryIMP.self)
        guard let view = factoryFunc(factory, selector, audioUnit, size) else {
            logger.warning("uiViewForAudioUnit:withSize: returned nil")
            return nil
        }

        logger.info("Loaded custom Cocoa AU view via \(className)")
        return view
    }

    private func loadGenericView(for audioUnit: AudioUnit) -> NSView {
        let view = AUGenericView(audioUnit: audioUnit)
        view.showsExpertParameters = true
        return view
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    let entryID: UUID
    weak var manager: AUPluginWindowManager?

    init(entryID: UUID, manager: AUPluginWindowManager) {
        self.entryID = entryID
        self.manager = manager
    }

    func windowWillClose(_ notification: Notification) {
        manager?.windowDidClose(entryID: entryID)
    }
}
