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
            // Nudge closer to the system OSD's typical top-right position.
            // Slightly tighter margins help cover the hollow OSD.
            let marginX: CGFloat = 10
            let marginY: CGFloat = 8
            let x = screen.visibleFrame.maxX - sw - marginX
            let y = screen.visibleFrame.maxY - sh - marginY
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

    var volumeLevel: CGFloat = 0 { didSet { updateUI() } }
    var isMuted: Bool = false    { didSet { updateUI() } }
    var deviceName: String = ""  { didSet { updateUI() } }

    private let blurView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let barTrack = NSView()
    private let barFill = NSView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Background blur (HUD style)
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 14
        blurView.layer?.masksToBounds = true
        blurView.layer?.borderWidth = 1
        blurView.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        addSubview(blurView)

        // Icon
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.contentTintColor = .white
        addSubview(iconView)

        // Label
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        // Track
        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = 5
        barTrack.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        addSubview(barTrack)

        // Fill
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 5
        barFill.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
        barFill.layer?.shadowColor = NSColor.systemBlue.cgColor
        barFill.layer?.shadowOpacity = 0.35
        barFill.layer?.shadowRadius = 6
        barFill.layer?.shadowOffset = .zero
        barTrack.addSubview(barFill)

        updateUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        blurView.frame = bounds

        let inset: CGFloat = 14
        let iconSize: CGFloat = 18
        iconView.frame = NSRect(x: inset, y: 16, width: iconSize, height: iconSize)

        let labelX = inset + iconSize + 10
        label.frame = NSRect(x: labelX, y: 15, width: bounds.width - labelX - inset, height: 18)

        let barY: CGFloat = 42
        let barH: CGFloat = 10
        let barW = bounds.width - inset * 2
        barTrack.frame = NSRect(x: inset, y: barY, width: barW, height: barH)

        updateBar(animated: false)
    }

    private func updateUI() {
        let pct = Int(round(volumeLevel * 100))
        label.stringValue = isMuted ? "Muted" : "\(pct)%  \(deviceName)"

        let symbolName: String
        if isMuted {
            symbolName = "speaker.slash.fill"
        } else if volumeLevel > 0.66 {
            symbolName = "speaker.wave.3.fill"
        } else if volumeLevel > 0.33 {
            symbolName = "speaker.wave.2.fill"
        } else if volumeLevel > 0 {
            symbolName = "speaker.wave.1.fill"
        } else {
            symbolName = "speaker.fill"
        }
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            iconView.image = img
        }

        updateBar(animated: true)
    }

    private func updateBar(animated: Bool) {
        let level = isMuted ? 0 : max(0.0, min(1.0, volumeLevel))
        let barW = barTrack.bounds.width
        let barH = barTrack.bounds.height
        let minW: CGFloat = barH
        let fillW = max(minW, barW * level)
        let newFrame = NSRect(x: 0, y: 0, width: fillW, height: barH)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                barFill.animator().frame = newFrame
            }
        } else {
            barFill.frame = newFrame
        }
    }
}
