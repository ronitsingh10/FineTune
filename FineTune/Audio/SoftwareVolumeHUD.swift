// FineTune/Audio/SoftwareVolumeHUD.swift
//
// A standalone NSPanel-based volume indicator that appears in the bottom-right
// corner of the primary screen when software volume changes.
// This replaces our attempt to use the macOS BezelServices OSD, which is
// inaccessible without private API entitlements on modern macOS.

import AppKit

@MainActor
final class SoftwareVolumeHUD {

    // MARK: - Singleton

    static let shared = SoftwareVolumeHUD()
    private init() {}

    // MARK: - State

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    // MARK: - Public API

    /// Show the HUD at `volume` (0–1). Call on main thread.
    func show(volume: Float, isMuted: Bool, deviceName: String) {
        let level = max(0.0, min(1.0, volume))

        // Build or reuse the panel
        let p = panel ?? makePanel()
        panel = p

        // Update contents
        if let hudView = p.contentView as? HUDContentView {
            hudView.volumeLevel = isMuted ? 0 : CGFloat(level)
            hudView.isMuted = isMuted
            hudView.deviceName = deviceName
            hudView.needsDisplay = true
        }

        // Position to overlap the system OSD — top-right, just below the menu bar.
        // If our window level beats SystemUIServer we cover the hollow OSD.
        // If not, both are visible (option 3 fallback).
        if let screen = NSScreen.main {
            let sw = p.frame.width
            let sh = p.frame.height
            let margin: CGFloat = 24
            let x = screen.visibleFrame.maxX - sw - margin
            let y = screen.visibleFrame.maxY - sh - margin
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()

        // Auto-hide after 1.8 s
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            } completionHandler: {
                p.orderOut(nil)
                p.alphaValue = 1
            }
        }
    }

    // MARK: - Panel Construction

    private func makePanel() -> NSPanel {
        let w: CGFloat = 300
        let h: CGFloat = 72
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = HUDContentView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        return p
    }
}

// MARK: - HUD Content View

private final class HUDContentView: NSView {

    var volumeLevel: CGFloat = 0 { didSet { needsDisplay = true } }
    var isMuted: Bool = false    { didSet { needsDisplay = true } }
    var deviceName: String = ""  { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let r = bounds
        let cornerRadius: CGFloat = 14

        // Background pill — dark translucent
        let bg = NSColor(white: 0.13, alpha: 0.92)
        bg.setFill()
        NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        // ── Label row ─────────────────────────────────────────────────────────
        let labelY: CGFloat = 14
        let iconStr = isMuted ? "🔇" : (volumeLevel > 0.5 ? "🔊" : (volumeLevel > 0 ? "🔉" : "🔈"))
        let icon = NSAttributedString(
            string: iconStr,
            attributes: [.font: NSFont.systemFont(ofSize: 16)]
        )
        icon.draw(at: NSPoint(x: 14, y: labelY))

        let nameAttr = NSAttributedString(
            string: isMuted ? "Muted" : "\(Int(round(volumeLevel * 100)))%  \(deviceName)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        nameAttr.draw(at: NSPoint(x: 42, y: labelY + 1))

        // ── Fill bar ──────────────────────────────────────────────────────────
        let barX: CGFloat = 14
        let barY: CGFloat = 44
        let barH: CGFloat = 10
        let barW = r.width - 28
        let barRadius: CGFloat = barH / 2

        // Track
        let trackColor = NSColor(white: 1, alpha: 0.18)
        trackColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH),
                     xRadius: barRadius, yRadius: barRadius).fill()

        // Fill
        let fillW = max(barRadius * 2, barW * (isMuted ? 0 : volumeLevel))
        let fillGrad = NSGradient(
            colors: [NSColor(red: 0.30, green: 0.80, blue: 1.0, alpha: 1),
                     NSColor(red: 0.10, green: 0.55, blue: 1.0, alpha: 1)],
            atLocations: [0, 1],
            colorSpace: .sRGB
        )
        ctx.saveGState()
        let fillPath = NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: fillW, height: barH),
                                    xRadius: barRadius, yRadius: barRadius)
        fillPath.addClip()
        fillGrad?.draw(in: NSRect(x: barX, y: barY, width: fillW, height: barH), angle: 0)
        ctx.restoreGState()
    }
}
