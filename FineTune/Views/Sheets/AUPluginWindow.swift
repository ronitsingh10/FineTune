// FineTune/Views/Sheets/AUPluginWindow.swift
import AppKit
import AudioToolbox
import CoreAudioKit
import os

enum AUPluginEditorInvalidation {
    static func perform(saveBeforeClose: Bool, save: () -> Void, detach: () -> Void, close: () -> Void) {
        if saveBeforeClose { save() }
        detach()
        close()
    }
}

enum AUPluginEditorRegistry {
    static func shouldReuse(cachedHostID: ObjectIdentifier?, requestedHostID: ObjectIdentifier) -> Bool {
        cachedHostID == requestedHostID
    }
}

@MainActor
enum AUPluginEditorSizing {
    static let fallbackContentSize = NSSize(width: 400, height: 300)
    /// Neoverb's complete remote AUv2 surface measures 800×600 points. This is
    /// also a useful expanded hint for remote plug-in views that publish no
    /// intrinsic size; fixed-size plug-ins can still return a larger frame.
    static let expandedCustomViewSize = NSSize(width: 800, height: 600)
    static let editorWindowStyle: NSWindow.StyleMask = [.titled, .closable, .resizable]

    /// Audio Unit v2 views receive a host-provided screen-size hint. Some remote
    /// views, including iZotope Neoverb, do not publish a native size. Request
    /// the measured expanded surface while keeping it within the current screen.
    static func customViewRequestSize(forVisibleFrame visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else { return expandedCustomViewSize }
        let available = NSWindow.contentRect(forFrameRect: visibleFrame, styleMask: editorWindowStyle).size
        return NSSize(
            width: min(expandedCustomViewSize.width, available.width),
            height: min(expandedCustomViewSize.height, available.height)
        )
    }

    static func preferredContentSize(for view: NSView) -> NSSize {
        view.layoutSubtreeIfNeeded()

        let intrinsic = view.intrinsicContentSize
        let candidates = [
            view.frame.size,
            view.bounds.size,
            view.fittingSize,
            intrinsic
        ]

        return candidates.reduce(fallbackContentSize) { result, candidate in
            NSSize(
                width: valid(candidate.width) ? max(result.width, candidate.width) : result.width,
                height: valid(candidate.height) ? max(result.height, candidate.height) : result.height
            )
        }
    }

    private static func valid(_ dimension: CGFloat) -> Bool {
        dimension.isFinite && dimension > 0 && dimension != NSView.noIntrinsicMetric
    }
}

@MainActor
final class AUPluginWindowManager {
    static let shared = AUPluginWindowManager()

    private var windows: [UUID: NSWindow] = [:]
    private var hostIDs: [UUID: ObjectIdentifier] = [:]
    // NSWindow keeps its delegate weakly. Keep each delegate alive for as long
    // as its window is open so that close-time state saving is reliable.
    private var windowDelegates: [UUID: WindowDelegate] = [:]
    private var saveCallbacks: [UUID: () -> Void] = [:]
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUPluginWindow")

    func showWindow(for entryID: UUID, host: AUEffectHost, audioUnit: AudioUnit, pluginName: String, forceGeneric: Bool = false, onSave: @escaping () -> Void) {
        if let existing = windows[entryID] {
            if AUPluginEditorRegistry.shouldReuse(cachedHostID: hostIDs[entryID], requestedHostID: ObjectIdentifier(host)) {
                existing.orderFrontRegardless()
                return
            }
            invalidate(entryIDs: [entryID])
        }

        let visibleFrame = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let requestedCustomSize = AUPluginEditorSizing.customViewRequestSize(forVisibleFrame: visibleFrame)
        let contentView = forceGeneric
            ? loadGenericView(for: audioUnit)
            : (loadCustomView(for: audioUnit, preferredSize: requestedCustomSize) ?? loadGenericView(for: audioUnit))

        let contentSize = AUPluginEditorSizing.preferredContentSize(for: contentView)
        contentView.frame = NSRect(origin: .zero, size: contentSize)
        contentView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: AUPluginEditorSizing.editorWindowStyle,
            backing: .buffered,
            defer: false
        )
        window.title = pluginName
        window.contentView = contentView
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let delegate = WindowDelegate(entryID: entryID, manager: self)
        window.delegate = delegate
        window.orderFrontRegardless()

        windows[entryID] = window
        hostIDs[entryID] = ObjectIdentifier(host)
        windowDelegates[entryID] = delegate
        saveCallbacks[entryID] = onSave
        logger.info("Opened AU window for \(pluginName) at \(Int(contentSize.width))x\(Int(contentSize.height))")
    }

    func closeWindow(for entryID: UUID) {
        guard let window = windows[entryID] else { return }
        window.close()

        // NSWindow normally synchronously calls windowWillClose. Retain a
        // fallback for a window implementation that does not notify its
        // delegate; finishWindow is idempotent, so this never saves twice.
        if windows[entryID] != nil {
            finishWindow(entryID: entryID)
        }
    }

    func closeAllWindows() {
        let entryIDs = Array(windows.keys)
        for entryID in entryIDs {
            closeWindow(for: entryID)
        }
    }

    /// Saves each current editor once, then removes its callback before closing
    /// so replacement teardown cannot write stale state into a new host.
    func invalidate(entryIDs: Set<UUID>, saveBeforeClose: Bool = true) {
        for entryID in entryIDs {
            let window = windows[entryID]
            AUPluginEditorInvalidation.perform(
                saveBeforeClose: saveBeforeClose,
                save: { self.saveCallbacks[entryID]?() },
                detach: {
                    self.saveCallbacks.removeValue(forKey: entryID)
                    self.windows.removeValue(forKey: entryID)
                    self.hostIDs.removeValue(forKey: entryID)
                    self.windowDelegates.removeValue(forKey: entryID)
                },
                close: { window?.close() }
            )
        }
    }

    func saveAllOpenWindows() {
        for callback in saveCallbacks.values {
            callback()
        }
    }

    fileprivate func windowDidClose(entryID: UUID) {
        finishWindow(entryID: entryID)
    }

    private func finishWindow(entryID: UUID) {
        guard let callback = saveCallbacks.removeValue(forKey: entryID) else { return }
        windows.removeValue(forKey: entryID)
        hostIDs.removeValue(forKey: entryID)
        windowDelegates.removeValue(forKey: entryID)
        callback()
    }

    // MARK: - View Loading

    private func loadCustomView(for audioUnit: AudioUnit, preferredSize: NSSize) -> NSView? {
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
        // Call via IMP with correct C types — NSObject.perform() would corrupt
        // the AudioUnit pointer (OpaquePointer, not AnyObject).
        typealias AUViewFactoryIMP = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> NSView?
        guard let method = class_getInstanceMethod(viewClass, selector) else {
            logger.warning("Failed to get method for \(selector)")
            return nil
        }
        let imp = method_getImplementation(method)
        let factoryFunc = unsafeBitCast(imp, to: AUViewFactoryIMP.self)
        guard let view = factoryFunc(factory, selector, audioUnit, preferredSize) else {
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
