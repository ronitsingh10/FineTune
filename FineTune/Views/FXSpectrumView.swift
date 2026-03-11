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
//   • Total bars on screen = NUM_BANDS × BARS_PER_BAND = 10 × 10 = 100.
//   • Gradient fill: accent colour bright at top/bottom, dimmer at mid (FxSound gloss).
//   • ~30 fps via CVDisplayLink (matches FxSound's VBlank target).

import SwiftUI
import CoreVideo

// MARK: - SwiftUI wrapper

struct FXSpectrumView: NSViewRepresentable {
    let isEnabled:   Bool
    let audioEngine: AudioEngine
    // Colour passed explicitly from the call site so it is always resolved
    // at SwiftUI body time — not inside NSViewRepresentable callbacks where
    // the environment may still reflect the previous animation frame.
    let accentR: CGFloat
    let accentG: CGFloat
    let accentB: CGFloat

    func makeCoordinator() -> SpectrumCoordinator { SpectrumCoordinator() }

    func makeNSView(context: Context) -> SpectrumNSView {
        let v = SpectrumNSView()
        push(context.coordinator)   // set correct colour BEFORE display link starts
        context.coordinator.attach(to: v, engine: audioEngine)
        return v
    }

    func updateNSView(_ nsView: SpectrumNSView, context: Context) {
        push(context.coordinator)
    }

    private func push(_ c: SpectrumCoordinator) {
        c.configure(r: accentR, g: accentG, b: accentB, enabled: isEnabled)
    }
}

// MARK: - Coordinator

final class SpectrumCoordinator {

    static let numBands    = 10
    static let barsPerBand = 10         // FxSound NUM_BARS
    static let totalBars   = numBands * barsPerBand

    // bandGraph: [band 0 bar0..bar3, band 1 bar0..bar3, … band 9 bar0..bar3]
    // Within each group: [oldest, newer, newest(centre), older] — symmetric bloom
    private var bandGraph = [Float](repeating: 0, count: totalBars)

    private weak var view:   SpectrumNSView?
    private weak var engine: AudioEngine?
    private var displayLink: CVDisplayLink?

    private var cr: CGFloat = 0; private var cg: CGFloat = 0; private var cb: CGFloat = 0
    private var enabled: Bool = true
    private var wasEnabled: Bool = true
    private var needsDisabledRefresh: Bool = false
    private var disabledStepCounter: Int = 0
    private static let disabledStepEveryFrames = 6   // ~1s crawl-to-flat with 10-history bars @30fps
    // Prevents rendering with default colours before the theme colour is pushed
    private var isConfigured: Bool = false

    func attach(to v: SpectrumNSView, engine: AudioEngine) {
        self.view   = v
        self.engine = engine
        startDisplayLink()
    }

    func configure(r: CGFloat, g: CGFloat, b: CGFloat, enabled: Bool) {
        isConfigured = true
        if !enabled {
            needsDisabledRefresh = true
        }
        cr = r; cg = g; cb = b; self.enabled = enabled
    }

    private func startDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        displayLink = dl

        let ctx = Unmanaged.passRetained(self)
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, raw in
            let coordinator = Unmanaged<SpectrumCoordinator>.fromOpaque(raw!).takeUnretainedValue()
            // Ensure we only touch @MainActor state (AudioEngine/@Observable) on main.
            DispatchQueue.main.async {
                coordinator.tickOnMain()
            }
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

    @MainActor
    private func tickOnMain() {
        guard isConfigured else { return }  // don't render before theme colour is set
        frameSkip.toggle()
        guard !frameSkip else { return }   // ~30 fps

        if !enabled {
            if wasEnabled {
                wasEnabled = false
                disabledStepCounter = 0
                needsDisabledRefresh = true  // switch to grayscale immediately
            }

            disabledStepCounter += 1
            if disabledStepCounter >= Self.disabledStepEveryFrames {
                disabledStepCounter = 0
                pushHistoryZeros()
                needsDisabledRefresh = true
            }

            if needsDisabledRefresh {
                view?.refresh(bandGraph: bandGraph, r: cr, g: cg, b: cb, enabled: false)
                needsDisabledRefresh = false
            }
            return
        }
        wasEnabled = true
        disabledStepCounter = 0

        guard let eng = engine else { return }
        let rawBands = eng.spectrumBandLevels   // [Float] × 10

        // FxSound scrolling-history update:
        // shift each half outward and insert newest sample at center.
        pushHistory(rawBands: rawBands)

        let snap = bandGraph
        let r = cr; let g = cg; let b = cb
        let en = enabled
        view?.refresh(bandGraph: snap, r: r, g: g, b: b, enabled: en)
    }

    private func pushHistory(rawBands: [Float]) {
        let N = Self.barsPerBand
        let half = N / 2

        for band in 0..<Self.numBands {
            let base = band * N
            let inVal = band < rawBands.count ? rawBands[band] : 0
            let newVal: Float
            if inVal.isNaN || !inVal.isFinite {
                newVal = 0
            } else {
                newVal = min(1, max(0, inVal))
            }

            for j in 0..<half {
                let src = bandGraph[base + j + 1]
                bandGraph[base + j]         = src
                bandGraph[base + N - 1 - j] = src
            }
            bandGraph[base + half] = newVal
        }
    }

    private func pushHistoryZeros() {
        pushHistory(rawBands: Array(repeating: 0, count: Self.numBands))
    }
}

// MARK: - NSView

final class SpectrumNSView: NSView {

    private var bandGraph = [Float](repeating: 0, count: SpectrumCoordinator.totalBars)
    private var r: CGFloat = 0; private var g: CGFloat = 0; private var b: CGFloat = 0
    private var enabled = true
    private var isConfigured = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    func refresh(bandGraph: [Float], r: CGFloat, g: CGFloat, b: CGFloat, enabled: Bool) {
        self.bandGraph = bandGraph
        self.r = r; self.g = g; self.b = b
        self.enabled = enabled
        self.isConfigured = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Prevent initial flash with fallback/default color before theme color arrives.
        guard isConfigured else { return }
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
            let rawSource = bandGraph[i]
            // Keep slight floor-lift only while FX is enabled; when disabled we must
            // allow bars to decay fully to flat as zero-history propagates.
            let raw = (enabled && rawSource == 0) ? 0.01 : rawSource
            // Livelier at low levels, but with soft-knee compression so peaks
            // don't pin at full height constantly.
            let floor: CGFloat = 0.002
            let level = max(0, CGFloat(raw) - floor)
            // Stronger overall motion across low/medium/high content.
            let driven = min(1.0, level * 4.6)
            let lifted = pow(driven, 0.43)
            let boosted = min(1.0, 1.0 - exp(-8.2 * lifted))
            let minHalfH: CGFloat = enabled ? 2.0 : 0.7
            let halfH = max(minHalfH, boosted * midY * 0.93)
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
