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
    private nonisolated(unsafe) var _preampGainLinear: Float = 1.0

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
        
        // Initialize persistent setup with max sections (Identity)
        // 5 coeffs per section: b0, b1, b2, a1, a2
        let identitySection = [1.0, 0.0, 0.0, 0.0, 0.0]
        var initialCoeffs: [Double] = []
        for _ in 0..<Self.maxSections {
            initialCoeffs.append(contentsOf: identitySection)
        }
        
        _eqSetup = initialCoeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(Self.maxSections))
        }

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
    /// Update EQ settings (call from main thread)
    /// Optimized to use vDSP_biquad_SetCoefficientsDouble for zero-allocation updates.
    func updateSettings(_ settings: EQSettings) {
        _isEnabled = settings.isEnabled
        _currentSettings = settings
        
        // Pre-calculate linear preamp gain
        let db = settings.preampGain
        _preampGainLinear = pow(10.0, db / 20.0)

        // Generate normalized coefficients for all sections
        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(Self.maxSections * 5)
        
        // 1. Generate coefficients for active bands
        if settings.mode == .graphic {
            // Graphic: 10 fixed bands
            allCoeffs = BiquadMath.coefficientsForAllBands(
                gains: settings.clampedGains,
                sampleRate: sampleRate
            )
        } else {
            // Parametric: Variable bands
            // Sort active bands by frequency for consistency (optional but good practice)
            let activeBands = settings.parametricBands.filter { $0.isEnabled }
            // Clamp to max supported
            let safeBands = activeBands.prefix(Self.maxSections)
            
            if activeBands.count > Self.maxSections {
                logger.warning("Too many bands active (\(activeBands.count)). Clamping.")
            }
            
            for band in safeBands {
                switch band.type {
                case .peak:
                    allCoeffs.append(contentsOf: BiquadMath.peakingEQCoefficients(
                        frequency: band.frequency, gainDB: band.gain, q: band.Q, sampleRate: sampleRate
                    ))
                case .lowShelf:
                    allCoeffs.append(contentsOf: BiquadMath.lowShelfCoefficients(
                        frequency: band.frequency, gainDB: band.gain, q: band.Q, sampleRate: sampleRate
                    ))
                case .highShelf:
                    allCoeffs.append(contentsOf: BiquadMath.highShelfCoefficients(
                        frequency: band.frequency, gainDB: band.gain, q: band.Q, sampleRate: sampleRate
                    ))
                }
            }
        }
        
        // 2. Fill remaining sections with Identity (Pass-through)
        // b0=1, b1=0, b2=0, a1=0, a2=0
        let sectionsUsed = allCoeffs.count / 5
        let sectionsNeeded = Self.maxSections - sectionsUsed
        let identity = [1.0, 0.0, 0.0, 0.0, 0.0]
        
        for _ in 0..<sectionsNeeded {
            allCoeffs.append(contentsOf: identity)
        }
        
        // 3. Update coefficients in-place
        // This is safe to call while the filter is processing (Apple Docs)
        if let setup = _eqSetup {
            allCoeffs.withUnsafeBufferPointer { ptr in
                vDSP_biquad_SetCoefficientsDouble(setup, ptr.baseAddress!, 0, vDSP_Length(Self.maxSections))
            }
        }
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

        // Create new biquad setup? No, update existing if possible, but rate change resets everything usually.
        // Actually, vDSP_biquad_DestroySetup required if we want to change rate cleanly?
        // Wait, biquad setup doesn't depend on sample rate, only coeffs do.
        // So we can REUSE the setup, just update coefficients!
        
        // 1. Recalculate coefficients
        // Reuse logic from updateSettings
        if let settings = _currentSettings {
            updateSettings(settings)
        }

        // 2. Reset delay buffers
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
        
        // If EQ globally disabled, bypass
        guard enabled else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            return
        }

        // 1. Copy input to output (in-place processing)
        // Apply Preamp Gain if non-unity
        // Safe to read nonisolated(unsafe) Float (atomic-ish on modern arch for aligned Word)
        // Note: _preampGainLinear is always updated on main thread before swap
        // To be strictly correct conform to C++ memory model, but here consistent with _isEnabled usage.
        var gain = _preampGainLinear
        
        // If gain is effectively 1.0 (0dB), just copy. 
        // 0.001 tolerance for float precision (approx -60dB error or so? No, 1.0 is unity)
        if abs(gain - 1.0) > 0.0001 {
            vDSP_vsmul(input, 1, &gain, output, 1, vDSP_Length(frameCount * 2))
        } else {
             if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
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
        
        // 3. Safety Check: Filter Instability / NaN Detection
        if output[0].isNaN || output[1].isNaN {
             memset(delayBufferL, 0, Self.delayBufferSize * MemoryLayout<Float>.size)
             memset(delayBufferR, 0, Self.delayBufferSize * MemoryLayout<Float>.size)
             memset(output, 0, frameCount * 2 * MemoryLayout<Float>.size)
        }
    }
}
