// FineTune/Views/FXSpectrumView.swift
//
// Real-time spectrum visualizer.
// Reference: FxSound FxVisualizer.cpp
//
// 40 vertical bars symmetric about horizontal midline.
// Level = max peak across all active audio taps, polled directly via CVDisplayLink
// (does not wait for SwiftUI re-renders — audioLevels is a computed property,
//  so @Observable would never fire. We own the display link and poll each frame).
// EQ gains shape the bar envelope along the frequency axis.
// Silent → bars = 1.5pt minimum → dashed-line appearance.
// Disabled (FX off) → desaturated grey.

import SwiftUI
import CoreVideo

// MARK: - SwiftUI wrapper

struct FXSpectrumView: NSViewRepresentable {
    let gains:       [Float]
    let freqs:       [Double]
    let isEnabled:   Bool
    let audioEngine: AudioEngine

    @Environment(ThemeManager.self) private var theme

    func makeCoordinator() -> SpectrumCoordinator { SpectrumCoordinator() }

    func makeNSView(context: Context) -> SpectrumNSView {
        let v = SpectrumNSView()
        context.coordinator.attach(to: v, engine: audioEngine)
        push(context.coordinator)
        return v
    }

    func updateNSView(_ nsView: SpectrumNSView, context: Context) {
        push(context.coordinator)
    }

    private func push(_ c: SpectrumCoordinator) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        (NSColor(theme.accentColor).usingColorSpace(.sRGB) ?? .systemRed)
            .getRed(&r, green: &g, blue: &b, alpha: nil)
        c.configure(gains: gains, freqs: freqs, r: r, g: g, b: b, enabled: isEnabled)
    }
}

// MARK: - Coordinator

final class SpectrumCoordinator {
    static let barCount = 40

    // Display levels (0–1) per bar — written by display link, read by draw()
    private var displayLevels = [Float](repeating: 0, count: barCount)

    private weak var view: SpectrumNSView?
    private weak var engine: AudioEngine?
    private var displayLink: CVDisplayLink?

    // Config written from main thread, read from display link thread.
    // Float/Bool reads are atomic on arm64/x86_64 — no lock needed.
    private var gains:   [Float]  = Array(repeating: 0, count: 9)
    private var freqs:   [Double] = Array(repeating: 1000, count: 9)
    private var cr: CGFloat = 1; private var cg: CGFloat = 0; private var cb: CGFloat = 0
    private var enabled: Bool = true

    // Log-spaced bar centre frequencies 20 Hz → 20 kHz
    static let barFreqs: [Double] = {
        let logMin = log(20.0); let logMax = log(20000.0)
        return (0..<barCount).map { i in
            exp(logMin + Double(i) / Double(barCount - 1) * (logMax - logMin))
        }
    }()

    func attach(to v: SpectrumNSView, engine: AudioEngine) {
        self.view   = v
        self.engine = engine
        startDisplayLink()
    }

    func configure(gains: [Float], freqs: [Double],
                   r: CGFloat, g: CGFloat, b: CGFloat, enabled: Bool) {
        self.gains   = gains
        self.freqs   = freqs
        cr = r; cg = g; cb = b
        self.enabled = enabled
    }

    private func startDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        displayLink = dl
        let ctx = Unmanaged.passRetained(self)
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, rawCtx in
            Unmanaged<SpectrumCoordinator>.fromOpaque(rawCtx!)
                .takeUnretainedValue().tick()
            return kCVReturnSuccess
        }, ctx.toOpaque())
        CVDisplayLinkStart(dl)
    }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }

    // Called ~60fps off main thread — polls engine directly
    private func tick() {
        // Poll peak level directly — bypasses SwiftUI render cycle
        let level: Float
        if let eng = engine {
            level = eng.audioLevels.values.max() ?? 0
        } else {
            level = 0
        }

        let localGains = gains
        let localFreqs = freqs

        // Shape bars with EQ envelope
        let base = powf(max(0, level), 0.70)   // compress dynamic range
        var targets = [Float](repeating: 0, count: Self.barCount)
        for i in 0..<Self.barCount {
            let shape = eqShape(for: Self.barFreqs[i], gains: localGains, freqs: localFreqs)
            targets[i] = base * shape
        }

        // Fast-attack / slow-decay smoothing
        for i in 0..<Self.barCount {
            let d = targets[i] - displayLevels[i]
            displayLevels[i] += d * (d > 0 ? 0.65 : 0.10)
        }

        let snap = displayLevels
        let r = cr; let g = cg; let b = cb
        let en = enabled
        DispatchQueue.main.async { [weak view] in
            view?.refresh(levels: snap, r: r, g: g, b: b, enabled: en)
        }
    }

    // Interpolate EQ gain → multiplier (0.5…1.5) at a frequency
    private func eqShape(for freq: Double, gains: [Float], freqs: [Double]) -> Float {
        let n = min(gains.count, freqs.count)
        guard n > 0 else { return 1 }
        let logFreq = log(max(freq, 1))

        var lo = 0; var hi = n - 1
        for i in 0..<n { if log(max(freqs[i], 1)) <= logFreq { lo = i } }
        for i in stride(from: n-1, through: 0, by: -1) { if log(max(freqs[i], 1)) >= logFreq { hi = i } }

        let gain: Float
        if lo == hi {
            gain = gains[lo]
        } else {
            let t = Float((logFreq - log(max(freqs[lo], 1))) /
                          (log(max(freqs[hi], 1)) - log(max(freqs[lo], 1))))
            gain = gains[lo] + t * (gains[hi] - gains[lo])
        }
        return 1.0 + (gain / 12.0) * 0.5   // −12dB→0.5×, 0dB→1.0×, +12dB→1.5×
    }
}

// MARK: - NSView drawing

final class SpectrumNSView: NSView {
    private var levels  = [Float](repeating: 0, count: SpectrumCoordinator.barCount)
    private var r: CGFloat = 1; private var g: CGFloat = 0; private var b: CGFloat = 0
    private var enabled = true

    override var isFlipped:   Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    func refresh(levels: [Float], r: CGFloat, g: CGFloat, b: CGFloat, enabled: Bool) {
        self.levels  = levels
        self.r = r; self.g = g; self.b = b
        self.enabled = enabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width; let H = bounds.height
        let midY = H / 2

        let n    = SpectrumCoordinator.barCount
        let barW: CGFloat = 4
        let gap:  CGFloat = (W - CGFloat(n) * barW) / CGFloat(n - 1)
        let startX: CGFloat = 0

        // Base colour — desaturate when FX off
        let base: NSColor
        if enabled {
            base = NSColor(red: r, green: g, blue: b, alpha: 1)
        } else {
            let bri = 0.299 * r + 0.587 * g + 0.114 * b
            base = NSColor(red: bri, green: bri, blue: bri, alpha: 1)
        }
        let topColor = base.withAlphaComponent(0.88)
        let midColor = base.withAlphaComponent(0.55)

        for i in 0..<n {
            let halfH = max(1.5, CGFloat(levels[i]) * midY * 0.92)
            let x     = startX + CGFloat(i) * (barW + gap)
            let rect  = CGRect(x: x, y: midY - halfH, width: barW, height: halfH * 2)

            // Vertical gradient: bright at top/bottom, dim at center (FxSound gloss)
            guard let grad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [topColor.cgColor, midColor.cgColor, topColor.cgColor] as CFArray,
                locations: [0, 0.5, 1]
            ) else { continue }

            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: x, y: rect.minY),
                                   end:   CGPoint(x: x, y: rect.maxY),
                                   options: [])
            ctx.restoreGState()
        }
    }
}
