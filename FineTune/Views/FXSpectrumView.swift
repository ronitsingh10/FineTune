// FineTune/Views/FXSpectrumView.swift
//
// Real-time spectrum visualiser — matched to FxSound's FxVisualizer.cpp design.
//
// ARCHITECTURE (matching FxSound):
//   • 10 frequency bands (56 Hz – 10 kHz, log-spaced) driven by resonant IIR
//     bandpass filters in SpectrumBandAnalyzer / ProcessTapController.
//   • BARS_PER_BAND history bars per band, mirrored symmetrically about the
//     band centre. Current value appears at centre and scrolls outward —
//     this is the "vibrant shuffling" effect in FxSound.
//   • Total bars on screen = NUM_BANDS × BARS_PER_BAND = 10 × 4 = 40.
//   • Gradient fill: accent colour bright at top/bottom, dimmer at mid (FxSound gloss).
//   • ~30 fps via CVDisplayLink (matches FxSound's VBlank target).

import SwiftUI
import CoreVideo

// MARK: - SwiftUI wrapper

struct FXSpectrumView: NSViewRepresentable {
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
        (NSColor(theme.accentColor).usingColorSpace(.sRGB) ?? .systemBlue)
            .getRed(&r, green: &g, blue: &b, alpha: nil)
        c.configure(r: r, g: g, b: b, enabled: isEnabled)
    }
}

// MARK: - Coordinator

final class SpectrumCoordinator {

    static let numBands    = 10
    static let barsPerBand = 4          // must be even for symmetric mirroring
    static let totalBars   = numBands * barsPerBand

    // bandGraph: [band 0 bar0..bar3, band 1 bar0..bar3, … band 9 bar0..bar3]
    // Within each group: [oldest, newer, newest(centre), older] — symmetric bloom
    private var bandGraph = [Float](repeating: 0, count: totalBars)

    private weak var view:   SpectrumNSView?
    private weak var engine: AudioEngine?
    private var displayLink: CVDisplayLink?

    private var cr: CGFloat = 0; private var cg: CGFloat = 0.5; private var cb: CGFloat = 1
    private var enabled: Bool = true

    func attach(to v: SpectrumNSView, engine: AudioEngine) {
        self.view   = v
        self.engine = engine
        startDisplayLink()
    }

    func configure(r: CGFloat, g: CGFloat, b: CGFloat, enabled: Bool) {
        cr = r; cg = g; cb = b; self.enabled = enabled
    }

    private func startDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        displayLink = dl

        let ctx = Unmanaged.passRetained(self)
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, raw in
            Unmanaged<SpectrumCoordinator>.fromOpaque(raw!)
                .takeUnretainedValue().tick()
            return kCVReturnSuccess
        }, ctx.toOpaque())

        // ~30 fps: skip every other vblank
        CVDisplayLinkStart(dl)
    }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }

    // MARK: - Per-frame update (~60fps, but we throttle drawing to ~30fps)

    private var frameSkip = false

    private func tick() {
        frameSkip.toggle()
        guard !frameSkip else { return }   // ~30 fps

        guard let eng = engine else { return }
        let rawBands = eng.spectrumBandLevels   // [Float] × 10, non-isolated read

        let N = Self.barsPerBand   // 4
        let half = N / 2           // 2

        // FxSound scrolling-history update, adapted for BARS_PER_BAND bars per band:
        // Within each group of N bars, scroll outward from centre symmetrically.
        // Centre position = N/2 (holds the newest value).
        // Each frame: shift everything one step outward, insert new value at centre.
        for band in 0..<Self.numBands {
            let base = band * N
            let newVal = rawBands[band]

            // Shift: position j ← position j+1  (for left half 0…half-2)
            // Mirror: position (N-1-j) ← position j+1  (right half mirrors left)
            for j in 0..<(half - 1) {
                let src = bandGraph[base + j + 1]
                bandGraph[base + j]         = src
                bandGraph[base + N - 1 - j] = src
            }
            // Insert current value at both centre positions (half-1 and half)
            bandGraph[base + half - 1] = newVal
            bandGraph[base + half]     = newVal
        }

        let snap   = bandGraph
        let r = cr; let g = cg; let b = cb
        let en = enabled
        DispatchQueue.main.async { [weak view] in
            view?.refresh(bandGraph: snap, r: r, g: g, b: b, enabled: en)
        }
    }
}

// MARK: - NSView

final class SpectrumNSView: NSView {

    private var bandGraph = [Float](repeating: 0, count: SpectrumCoordinator.totalBars)
    private var r: CGFloat = 0; private var g: CGFloat = 0.5; private var b: CGFloat = 1
    private var enabled = true

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    func refresh(bandGraph: [Float], r: CGFloat, g: CGFloat, b: CGFloat, enabled: Bool) {
        self.bandGraph = bandGraph
        self.r = r; self.g = g; self.b = b
        self.enabled = enabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width
        let H = bounds.height
        let midY = H / 2

        let n     = SpectrumCoordinator.totalBars
        let barW: CGFloat = 4
        let gap   = (W - CGFloat(n) * barW) / CGFloat(n - 1)

        // Colour — desaturate when FX off (FxSound behaviour)
        let base: NSColor
        if enabled {
            base = NSColor(red: r, green: g, blue: b, alpha: 1)
        } else {
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            base = NSColor(red: luma, green: luma, blue: luma, alpha: 1)
        }
        let topCol = base.withAlphaComponent(0.9).cgColor
        let midCol = base.withAlphaComponent(0.45).cgColor

        for i in 0..<n {
            let raw = bandGraph[i]
            // Boost and power-curve the level so it fills the cell like FxSound.
            // The resonant filter output is naturally in 0.01–0.15 for loud audio;
            // a sqrt expand + 8× scale maps that to a good display range.
            let boosted = min(1.0, CGFloat(sqrtf(raw)) * 5.9)
            let halfH   = max(1.5, boosted * midY * 0.95)
            let x     = CGFloat(i) * (barW + gap)
            let rect  = CGRect(x: x, y: midY - halfH, width: barW, height: halfH * 2)

            guard let grad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [topCol, midCol, topCol] as CFArray,
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
