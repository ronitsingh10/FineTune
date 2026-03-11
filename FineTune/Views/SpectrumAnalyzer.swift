// FineTune/Views/SpectrumAnalyzer.swift
//
// Real-time spectrum analyzer using AVAudioEngine + vDSP FFT.
// Captures from the default input device. bandLevels: 9 values (0–1),
// matching the FX EQ band frequency ranges, with fast-attack / slow-decay smoothing.
//
// Requires com.apple.security.device.audio-input entitlement.
// If audio input is unavailable, bandLevels stays at zeros — ring renders silently.

import Accelerate
import AVFoundation
import Foundation

final class SpectrumAnalyzer {
    // Read from render thread; written atomically from audio callback.
    private(set) var bandLevels: [Float] = Array(repeating: 0, count: 9)

    private var engine:    AVAudioEngine?
    private var fftSetup:  FFTSetup?
    private var hannWin:   [Float]
    private var smoothed:  [Float] = Array(repeating: 0, count: 9)
    private let lock = NSLock()

    private let fftSize = 1024

    // Frequency ranges (Hz) — 9 bands matching the FX EQ layout
    private let bandRanges: [(lo: Float, hi: Float)] = [
        (30,   80),    // 0  sub-bass
        (80,   200),   // 1  bass
        (200,  400),   // 2  low-mid
        (400,  800),   // 3  low-mid focal
        (800,  1600),  // 4  center-mid
        (1600, 3200),  // 5  high-mid
        (3200, 6000),  // 6  lower-high (needle)
        (6000, 10000), // 7  center-high
        (10000, 20000) // 8  highest
    ]

    init() {
        hannWin = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWin, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    func start() {
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = Float(format.sampleRate)
        guard format.channelCount > 0, sampleRate > 0 else { return }

        input.installTap(onBus: 0,
                         bufferSize: AVAudioFrameCount(fftSize),
                         format: format) { [weak self] buf, _ in
            self?.analyze(buf, sampleRate: sampleRate)
        }

        do {
            try e.start()
            engine = e
        } catch {
            input.removeTap(onBus: 0)
            // Silently fail — ring operates without spectrum
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - Audio callback (non-main thread)

    private func analyze(_ buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let setup = fftSetup,
              let raw = buffer.floatChannelData?[0] else { return }
        let n = min(Int(buffer.frameLength), fftSize)

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(raw, 1, hannWin, 1, &windowed, 1, vDSP_Length(n))

        // Real-to-complex FFT via vDSP
        var realArr = [Float](repeating: 0, count: fftSize / 2)
        var imagArr = [Float](repeating: 0, count: fftSize / 2)
        var mag     = [Float](repeating: 0, count: fftSize / 2)

        realArr.withUnsafeMutableBufferPointer { rBuf in
            imagArr.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!,
                                            imagp: iBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { wBuf in
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                        capacity: fftSize / 2) { cBuf in
                        vDSP_ctoz(cBuf, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                let log2n = vDSP_Length(log2(Float(fftSize)))
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Normalise
        var scale = Float(1.0) / Float(fftSize)
        vDSP_vsmul(mag, 1, &scale, &mag, 1, vDSP_Length(fftSize / 2))

        // Bucket into 9 bands
        let binHz = sampleRate / Float(fftSize)
        var raw9 = [Float](repeating: 0, count: 9)
        for (idx, range) in bandRanges.enumerated() {
            let lo = max(1, Int(range.lo / binHz))
            let hi = min(Int(range.hi / binHz), fftSize / 2 - 1)
            guard lo <= hi else { continue }
            var rms: Float = 0
            mag.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + lo, 1, &rms, vDSP_Length(hi - lo + 1))
            }
            raw9[idx] = min(1.0, rms * 1400)   // empirical scale for mic input
        }

        // Fast-attack / slow-decay envelope
        lock.lock()
        for i in 0..<9 {
            let a: Float = raw9[i] > smoothed[i] ? 0.65 : 0.12
            smoothed[i] = smoothed[i] + (raw9[i] - smoothed[i]) * a
        }
        let result = smoothed
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.bandLevels = result
        }
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }
}
