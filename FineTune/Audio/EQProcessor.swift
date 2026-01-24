// FineTune/Audio/EQProcessor.swift
import Foundation
import Accelerate
import os

/// RT-safe 10-band graphic EQ processor using vDSP_biquad
final class EQProcessor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.finetune.audio", category: "EQProcessor")

    /// Number of delay samples per channel: (2 * sections) + 2
    /// Increased to accommodate up to 64 parametric bands (safe margin)
    private static let maxSections = 64
    private static let delayBufferSize = (2 * maxSections) + 2

    private var sampleRate: Double

    /// Currently applied EQ settings (needed for sample rate updates)
    private var _currentSettings: EQSettings?

    /// Read-only access to current settings
    var currentSettings: EQSettings? { _currentSettings }

    // Lock-free state for RT-safe access
    private nonisolated(unsafe) var _eqSetup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var _isEnabled: Bool = true

    // Pre-allocated delay buffers (raw pointers for RT-safety)
    private let delayBufferL: UnsafeMutablePointer<Float>
    private let delayBufferR: UnsafeMutablePointer<Float>

    /// Whether EQ processing is enabled
    var isEnabled: Bool {
        get { _isEnabled }
    }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate

        // Allocate raw buffers (done once, on main thread)
        delayBufferL = UnsafeMutablePointer<Float>.allocate(capacity: Self.delayBufferSize)
        delayBufferL.initialize(repeating: 0, count: Self.delayBufferSize)

        delayBufferR = UnsafeMutablePointer<Float>.allocate(capacity: Self.delayBufferSize)
        delayBufferR.initialize(repeating: 0, count: Self.delayBufferSize)

        // Initialize with flat EQ
        updateSettings(EQSettings.flat)
    }

    deinit {
        if let setup = _eqSetup {
            vDSP_biquad_DestroySetup(setup)
        }
        delayBufferL.deallocate()
        delayBufferR.deallocate()
    }

    /// Update EQ settings (call from main thread)
    func updateSettings(_ settings: EQSettings) {
        _isEnabled = settings.isEnabled
        _currentSettings = settings

        let coefficients: [Double]
        let bandCount: vDSP_Length
        
        if settings.mode == .graphic {
            // Legacy Path: 10-band Graphic EQ
            coefficients = BiquadMath.coefficientsForAllBands(
                gains: settings.clampedGains,
                sampleRate: sampleRate
            )
            bandCount = vDSP_Length(EQSettings.bandCount)
        } else {
            // Parametric Path: Variable bands
            var coeffs: [Double] = []
            let activeBands = settings.parametricBands.filter { $0.isEnabled }
            bandCount = vDSP_Length(activeBands.count)
            
            for band in activeBands {
                let bandCoeffs: [Double]
                switch band.type {
                case .peak:
                    bandCoeffs = BiquadMath.peakingEQCoefficients(
                        frequency: band.frequency,
                        gainDB: band.gain,
                        q: band.Q,
                        sampleRate: sampleRate
                    )
                case .lowShelf:
                    bandCoeffs = BiquadMath.lowShelfCoefficients(
                        frequency: band.frequency,
                        gainDB: band.gain,
                        q: band.Q,
                        sampleRate: sampleRate
                    )
                case .highShelf:
                    bandCoeffs = BiquadMath.highShelfCoefficients(
                        frequency: band.frequency,
                        gainDB: band.gain,
                        q: band.Q,
                        sampleRate: sampleRate
                    )
                }
                coeffs.append(contentsOf: bandCoeffs)
            }
            coefficients = coeffs
        }
        
        // Ensure at least one band exists to create a valid setup
        let newSetup: vDSP_biquad_Setup?
        if bandCount > 0 {
            newSetup = coefficients.withUnsafeBufferPointer { ptr in
                vDSP_biquad_CreateSetup(ptr.baseAddress!, bandCount)
            }
        } else {
            newSetup = nil
        }

        // Swap setup atomically
        let oldSetup = _eqSetup
        _eqSetup = newSetup

        // Destroy old setup on background queue (after audio thread has moved on)
        if let old = oldSetup {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                vDSP_biquad_DestroySetup(old)
            }
        }

        // Note: Do NOT reset delay buffers here - the filter naturally adapts to new
        // coefficients using existing state, producing smooth transitions without clicks.
        // Delay buffers are only reset on init and sample rate changes.
    }

    /// Updates the sample rate and recalculates all biquad coefficients.
    /// Call this when the output device changes to a different sample rate.
    /// Thread-safe: uses atomic swap for RT-safety.
    ///
    /// - Parameter newRate: The new device sample rate in Hz (e.g., 44100, 48000, 96000)
    func updateSampleRate(_ newRate: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        let oldRate = sampleRate
        guard newRate != sampleRate else { return }  // No change needed
        guard let settings = _currentSettings else {
            // No settings applied yet, just update the rate for future use
            sampleRate = newRate
            logger.info("[EQ] Sample rate updated: \(oldRate, format: .fixed(precision: 0))Hz → \(newRate, format: .fixed(precision: 0))Hz")
            return
        }

        // Update stored rate
        sampleRate = newRate
        logger.info("[EQ] Sample rate updated: \(oldRate, format: .fixed(precision: 0))Hz → \(newRate, format: .fixed(precision: 0))Hz")

        // Recalculate coefficients with new sample rate
        // Check mode to decide how to generate coefficients
        let coefficients: [Double]
        let bandCount: vDSP_Length
        
        if settings.mode == .graphic {
            coefficients = BiquadMath.coefficientsForAllBands(
                gains: settings.clampedGains,
                sampleRate: newRate
            )
            bandCount = vDSP_Length(EQSettings.bandCount)
        } else {
            // Parametric Path
            var coeffs: [Double] = []
            let activeBands = settings.parametricBands.filter { $0.isEnabled }
            bandCount = vDSP_Length(activeBands.count)
            
            for band in activeBands {
                let bandCoeffs: [Double]
                switch band.type {
                case .peak:
                    bandCoeffs = BiquadMath.peakingEQCoefficients(
                        frequency: band.frequency,
                        gainDB: band.gain,
                        q: band.Q,
                        sampleRate: newRate
                    )
                case .lowShelf:
                    bandCoeffs = BiquadMath.lowShelfCoefficients(
                        frequency: band.frequency,
                        gainDB: band.gain,
                        q: band.Q,
                        sampleRate: newRate
                    )
                case .highShelf:
                    bandCoeffs = BiquadMath.highShelfCoefficients(
                        frequency: band.frequency,
                        gainDB: band.gain,
                        q: band.Q,
                        sampleRate: newRate
                    )
                }
                coeffs.append(contentsOf: bandCoeffs)
            }
            coefficients = coeffs
        }

        // Create new biquad setup
        let newSetup: vDSP_biquad_Setup?
        if bandCount > 0 {
             newSetup = coefficients.withUnsafeBufferPointer { ptr in
                vDSP_biquad_CreateSetup(ptr.baseAddress!, bandCount)
            }
        } else {
            newSetup = nil
        }

        // Atomic swap (RT-safe)
        let oldSetup = _eqSetup
        _eqSetup = newSetup

        // Destroy old setup asynchronously (avoid blocking)
        if let old = oldSetup {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                vDSP_biquad_DestroySetup(old)
            }
        }

        // Reset delay buffers to avoid filter artifacts from old state
        memset(delayBufferL, 0, Self.delayBufferSize * MemoryLayout<Float>.size)
        memset(delayBufferR, 0, Self.delayBufferSize * MemoryLayout<Float>.size)
    }

    /// Process stereo interleaved audio (RT-safe)
    /// - Parameters:
    ///   - input: Input buffer (stereo interleaved Float32)
    ///   - output: Output buffer (stereo interleaved Float32)
    ///   - frameCount: Number of stereo frames (samples / 2)
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Read atomic state
        let enabled = _isEnabled
        let setup = _eqSetup
        let settings = _currentSettings // Grab reference to settings for preamp
        
        // If EQ globally disabled, bypass
        guard enabled else {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            return
        }

        // 1. Copy input to output (in-place processing)
        // Apply Preamp Gain if non-zero
        let preampDB = settings?.preampGain ?? 0.0
        
        if abs(preampDB) > 0.001 {
            let linearGain = pow(10.0, preampDB / 20.0)
            var gain = linearGain // vDSP needs a variable pointer
            vDSP_vsmul(input, 1, &gain, output, 1, vDSP_Length(frameCount * 2))
        } else {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }
        
        // 2. Apply Biquads (if setup exists)
        if let setup = setup {
            // Process left channel (stride=2, starts at index 0)
            vDSP_biquad(
                setup,
                delayBufferL,
                output,
                2,
                output,
                2,
                vDSP_Length(frameCount)
            )

            // Process right channel (stride=2, starts at index 1)
            vDSP_biquad(
                setup,
                delayBufferR,
                output.advanced(by: 1),
                2,
                output.advanced(by: 1),
                2,
                vDSP_Length(frameCount)
            )
        }
    }
}
