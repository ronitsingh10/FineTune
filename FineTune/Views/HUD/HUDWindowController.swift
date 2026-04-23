// FineTune/Views/HUD/HUDWindowController.swift
import AppKit
import SwiftUI
import os

/// Owns the on-screen volume HUD panel and its auto-hide timing.
@MainActor
final class HUDWindowController {
    private let settingsManager: SettingsManager
    private let mediaKeyStatus: MediaKeyStatus
    private let popupVisibility: PopupVisibilityService
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "HUDWindowController")

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var styleAtLastShow: HUDStyle = .tahoe

    /// Invoked on every Tahoe slider drag; host wires this to volume + mute semantics.
    var volumeWriter: ((Float) -> Void)?

    // MARK: - Suppression-degraded tracking

    private var lastSwallowedKeyTime: DispatchTime?
    private var settingsChangedObserver: NSObjectProtocol?

    var hideDelayOverride: Duration?
    var frameProvider: () -> NSRect? = { NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame }
    private(set) var showCallCount: Int = 0
    private(set) var showDidUpdatePanel: Bool = false

    init(
        settingsManager: SettingsManager,
        mediaKeyStatus: MediaKeyStatus,
        popupVisibility: PopupVisibilityService
    ) {
        self.settingsManager = settingsManager
        self.mediaKeyStatus = mediaKeyStatus
        self.popupVisibility = popupVisibility
        subscribeToSettingsChangedNotification()
    }

    deinit {
        if let observer = settingsChangedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        // `deinit` is nonisolated; `shutdown()` is preferred for synchronous teardown.
        if let panel {
            DispatchQueue.main.async { panel.orderOut(nil) }
        }
    }

    /// Synchronous teardown for `willTerminate` — hides without animation.
    func shutdown() {
        hideTask?.cancel()
        hideTask = nil
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Style-indexed hide delay

    func hideDelay(for style: HUDStyle) -> Duration {
        if let override = hideDelayOverride { return override }
        switch style {
        case .tahoe: return .milliseconds(800)
        case .classic: return .milliseconds(1100)
        }
    }

    // MARK: - Public API

    /// Displays the HUD. Skipped when the foreground app is fullscreen or the popup is visible.
    func show(volume: Float, mute: Bool, deviceName: String) {
        showCallCount += 1
        showDidUpdatePanel = false

        let fullscreen = isForegroundAppFullscreen()
        let popupVisible = popupVisibility.isVisible
        logger.info("DIAG show() call=\(self.showCallCount) fullscreen=\(fullscreen) popupVisible=\(popupVisible) panelExists=\(self.panel != nil) panelIsVisible=\(self.panel?.isVisible ?? false)")

        guard !fullscreen else {
            logger.info("DIAG show() skipped: foreground fullscreen")
            return
        }
        guard !popupVisible else {
            logger.info("DIAG show() skipped: popup visible")
            return
        }

        let style = settingsManager.appSettings.hudStyle
        styleAtLastShow = style
        let panel = ensurePanel()

        // Classic is click-through; Tahoe takes mouse events for drag + hover.
        panel.ignoresMouseEvents = (style == .classic)

        let root: AnyView
        let size: NSSize
        switch style {
        case .tahoe:
            root = AnyView(
                TahoeStyleHUD(
                    volume: volume,
                    mute: mute,
                    deviceName: deviceName,
                    onVolumeChange: { [weak self] newVolume in
                        self?.volumeWriter?(newVolume)
                    },
                    onHoverChange: { [weak self] hovering in
                        self?.handleHoverChange(hovering)
                    }
                )
            )
            size = NSSize(width: 300, height: 72)
        case .classic:
            root = AnyView(ClassicStyleHUD(volume: volume, mute: mute))
            size = NSSize(width: 200, height: 200)
        }

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        panel.setFrameOrigin(position(for: style, size: size))

        let wasVisible = panel.isVisible
        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let duration = reduceMotionEnabled() ? 0.08 : 0.12
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }
        logger.info("DIAG show() after-orderFront wasVisible=\(wasVisible) nowVisible=\(panel.isVisible) occluded=\(panel.occlusionState.contains(.visible) ? false : true) frame=\(NSStringFromRect(panel.frame), privacy: .public) level=\(panel.level.rawValue) screen=\(panel.screen?.localizedName ?? "nil", privacy: .public)")

        scheduleHide(for: style)
        postAccessibilityAnnouncement(panel: panel, volume: volume, mute: mute, deviceName: deviceName)
    }

    /// Called when the monitor swallows a keypress; used to detect if the native HUD still fired.
    func swallowObserved() {
        lastSwallowedKeyTime = DispatchTime.now()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        let duration = reduceMotionEnabled() ? 0.08 : 0.11
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Position Math

    /// Tahoe: top-right. Classic: bottom-center. Under suppression-degraded,
    /// Tahoe shifts left so it doesn't overlap the native top-right HUD.
    static func computePosition(
        style: HUDStyle,
        size: NSSize,
        visibleFrame: NSRect,
        suppressionDegraded: Bool
    ) -> NSPoint {
        switch style {
        case .tahoe:
            if suppressionDegraded {
                let x = visibleFrame.minX + visibleFrame.width * 0.25 - size.width / 2
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            } else {
                let x = visibleFrame.maxX - size.width - 8
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            }
        case .classic:
            let x = visibleFrame.midX - size.width / 2
            let y = visibleFrame.minY + 140
            return NSPoint(x: x, y: y)
        }
    }

    private func position(for style: HUDStyle, size: NSSize) -> NSPoint {
        let frame = frameProvider() ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Self.computePosition(
            style: style,
            size: size,
            visibleFrame: frame,
            suppressionDegraded: mediaKeyStatus.suppressionDegraded
        )
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        // Needed for Tahoe hover/drag on a non-activating panel.
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false

        panel = p
        return p
    }

    private func scheduleHide(for style: HUDStyle) {
        hideTask?.cancel()
        let delay = hideDelay(for: style)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide(for: styleAtLastShow)
        }
    }

    // MARK: - Accessibility

    private func postAccessibilityAnnouncement(panel: NSPanel, volume: Float, mute: Bool, deviceName: String) {
        let description = accessibilityDescription(volume: volume, mute: mute, deviceName: deviceName)
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func accessibilityDescription(volume: Float, mute: Bool, deviceName: String) -> String {
        let device = deviceName.isEmpty ? "Unknown device" : deviceName
        if mute { return "\(device), muted" }
        let clamped = max(0, min(1, volume))
        return "\(device), volume \(Int((clamped * 100).rounded())) percent"
    }

    private func reduceMotionEnabled() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Fullscreen guard

    private func isForegroundAppFullscreen() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontmostApp.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let mainScreen = NSScreen.main else { return false }
        let screenFrame = mainScreen.frame
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let boundsRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            if boundsRect.width >= screenFrame.width && boundsRect.height >= screenFrame.height {
                return true
            }
        }
        return false
    }

    // MARK: - Suppression-degraded detection

    private func subscribeToSettingsChangedNotification() {
        settingsChangedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.sound.settingsChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSettingsChangedNotification()
            }
        }
    }

    private func handleSettingsChangedNotification() {
        guard let lastSwallow = lastSwallowedKeyTime else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastSwallow.uptimeNanoseconds
        let elapsedMs = elapsed / 1_000_000
        if elapsedMs <= 500 && !mediaKeyStatus.suppressionDegraded {
            mediaKeyStatus.suppressionDegraded = true
            logger.warning("Suppression degraded: native sound handler fired within \(elapsedMs)ms of our swallow")
        }
    }
}
