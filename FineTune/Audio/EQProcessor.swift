// FineTune/Audio/EQProcessor.swift
import Foundation
import Accelerate
import os

/// RT-safe 10-band graphic EQ processor using vDSP_biquad
final class EQProcessor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.finetune.audio", category: "EQProcessor")

    /// Number of delay samples per channel: (2 * sections) + 2
    private static let delayBufferSize = (2 * EQSettings.bandCount) + 2  // 22

    private var sampleRate: Double

    /// Currently applied EQ settings (needed for sample rate updates)
    private var _currentSettings: EQSettings?

    /// Read-only access to current settings
    var currentSettings: EQSettings? { _currentSettings }

    // Lock-free state for RT-safe access
    private nonisolated(unsafe) var _eqSetup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var _isEnabled: Bool = true
    /// Pre-EQ attenuation to prevent post-EQ clipping when bands are boosted.
    /// Computed as: pow(10, -maxBoostDB / 20) when any band has positive gain.
    /// Audio callback reads this atomically; main thread writes in updateSettings().
    private nonisolated(unsafe) var _preampAttenuation: Float = 1.0

    // Pre-allocated delay buffers (raw pointers for RT-safety)
    private let delayBufferL: UnsafeMutablePointer<Float>
    private let delayBufferR: UnsafeMutablePointer<Float>

    /// Whether EQ processing is enabled
    var isEnabled: Bool {
        get { _isEnabled }
    }

    /// Pre-EQ gain reduction to prevent clipping (RT-safe read)
    var preampAttenuation: Float { _preampAttenuation }

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

        // Compute pre-EQ attenuation to prevent post-EQ clipping
        let maxBoostDB = settings.clampedGains.max() ?? 0
        _preampAttenuation = maxBoostDB > 0 ? pow(10.0, -maxBoostDB / 20.0) : 1.0

        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )

        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }

        // Swap setup atomically
        let oldSetup = _eqSetup
        _eqSetup = newSetup

        // Destroy old setup on background queue (after audio thread has moved on)
        // 500ms margin: worst-case buffer is 4096 frames @ 44.1kHz = 93ms, plus scheduling jitter
        if let old = oldSetup {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
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
        // Development-only check (stripped in Release). Safe because callers are always @MainActor.
        // Note: delay buffer reset is protected by temporarily disabling EQ processing.
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
        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: newRate
        )

        // Create new biquad setup
        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }

        // Atomic swap (RT-safe)
        let oldSetup = _eqSetup
        _eqSetup = newSetup

        // Destroy old setup asynchronously (avoid blocking)
        // 500ms margin: worst-case buffer is 4096 frames @ 44.1kHz = 93ms, plus scheduling jitter
        if let old = oldSetup {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                vDSP_biquad_DestroySetup(old)
            }
        }

        // Disable EQ before resetting delay buffers to prevent race with vDSP_biquad
        // on audio thread. process() snapshots _isEnabled atomically at entry —
        // any callback starting after this barrier will bypass the biquad path.
        let wasEnabled = _isEnabled
        _isEnabled = false
        OSMemoryBarrier()

        // Reset delay buffers (safe: new callbacks bypass, in-flight callbacks
        // finish within microseconds since vDSP_biquad is SIMD-optimized)
        memset(delayBufferL, 0, Self.delayBufferSize * MemoryLayout<Float>.size)
        memset(delayBufferR, 0, Self.delayBufferSize * MemoryLayout<Float>.size)

        // Re-enable and publish
        _isEnabled = wasEnabled
        OSMemoryBarrier()
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

        // Bypass: copy input to output (skip if already in-place to avoid memcpy UB on overlap)
        guard enabled, let setup = setup else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            return
        }

        // Copy input to output first for in-place processing (skip if same buffer)
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }

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
