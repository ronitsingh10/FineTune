// FineTune/Audio/EQ/SVFProcessor.swift
import Foundation
import Darwin.C  // OSMemoryBarrier
import os

/// Setup structure for State Variable Filter processor
///
/// These are the delay buffers and running state for a single channel. Setup swaps do
/// not require them to be reset.
struct SVFProcessorState {
    var v1: Double = 0.0
    var v2: Double = 0.0
    var v3: Double = 0.0
    var ic1eq: Double = 0.0
    var ic2eq: Double = 0.0
}

/// Base class for RT-safe State Variable Filter processors.
///
/// Manages delay buffers, atomic setup swaps, and the core stereo SVF processing loop.
/// Subclasses provide coefficient computation via `recomputeCoefficients()` and optional
/// pre-processing via `preProcess()`.
///
/// ## RT-Safety
/// `process()` runs on CoreAudio's HAL I/O thread. All state it accesses uses
/// `nonisolated(unsafe)` for lock-free atomic reads. Setup updates use atomic pointer
/// swaps with deferred destruction (500ms grace period).
///
/// ## Subclasses
/// - `EQProcessor`: Per-app 10-band graphic EQ
/// - `AutoEQProcessor`: Per-device headphone correction
class SVFProcessor: @unchecked Sendable, SVFProcessable {

    let logger: Logger

    /// Current sample rate in Hz. Main thread only.
    private(set) var sampleRate: Double

    // MARK: - RT-Safe State

    /// SVF coefficients
    private nonisolated(unsafe) var _eqSectionCount: Int
    private nonisolated(unsafe) var _eqSetup: UnsafeMutablePointer<Double>?

    /// Processing enable flag. Audio callback reads this atomically at entry.
    /// Subclasses set via `setEnabled(_:)` from their update methods (main thread only).
    private nonisolated(unsafe) var _isEnabled: Bool

    // MARK: - Pre-allocated Delay Buffers

    private let delayBufferL: UnsafeMutablePointer<SVFProcessorState>
    private let delayBufferR: UnsafeMutablePointer<SVFProcessorState>
    private let delayBufferSize: Int

    /// Whether SVF processing is active (RT-safe read).
    var isEnabled: Bool { _isEnabled }

    /// Set the processing enable flag. Main thread only.
    func setEnabled(_ enabled: Bool) {
        _isEnabled = enabled
    }

    // MARK: - Init / Deinit

    /// - Parameters:
    ///   - sampleRate: Initial device sample rate in Hz.
    ///   - maxSections: Maximum number of SVF sections. Determines delay buffer size
    ///   - category: Logger category for this processor instance.
    ///   - initiallyEnabled: Whether processing starts enabled. Default `false`.
    init(sampleRate: Double, maxSections: Int, category: String, initiallyEnabled: Bool = false) {
        self.sampleRate = sampleRate
        self.logger = Logger(subsystem: "com.finetuneapp.FineTune", category: category)
        self._isEnabled = initiallyEnabled
        self._eqSectionCount = 0
        self.delayBufferSize = maxSections

        delayBufferL = .allocate(capacity: delayBufferSize)
        delayBufferL.initialize(repeating: SVFProcessorState(), count: delayBufferSize)
        delayBufferR = .allocate(capacity: delayBufferSize)
        delayBufferR.initialize(repeating: SVFProcessorState(), count: delayBufferSize)
    }

    deinit {
        _eqSetup?.deallocate()
        delayBufferL.deallocate()
        delayBufferR.deallocate()
    }

    // MARK: - Setup Management (main thread)

    /// Atomically swap the SVF setup, deferring destruction of the old one.
    ///
    /// The 500ms delay ensures the audio thread has moved on from the old setup.
    /// Worst-case audio buffer is 4096 frames @ 44.1kHz = 93ms, plus scheduling jitter.
    func swapSetup(_ newSetup: [Double]?) {
        let oldSetup = _eqSetup
        if let newSetup = newSetup {
            let count = newSetup.count
            let eqSetup = UnsafeMutablePointer<Double>.allocate(capacity: count)
            eqSetup.initialize(from: newSetup, count: count)
            _eqSetup = eqSetup
            _eqSectionCount = count / 6
        } else {
            _eqSetup = nil
            _eqSectionCount = 0
        }
        if let old = oldSetup {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                old.deallocate()
            }
        }
    }

    /// Reset delay buffers with barrier protection.
    ///
    /// Temporarily disables processing to prevent the audio thread from reading
    /// partially-zeroed state. Call from main thread after a sample rate change.
    func resetDelayBuffers() {
        let wasEnabled = _isEnabled
        _isEnabled = false
        OSMemoryBarrier()

        memset(delayBufferL, 0, delayBufferSize * MemoryLayout<SVFProcessorState>.size)
        memset(delayBufferR, 0, delayBufferSize * MemoryLayout<SVFProcessorState>.size)

        _isEnabled = wasEnabled
        OSMemoryBarrier()
    }

    /// Update sample rate and recompute coefficients.
    ///
    /// Calls `recomputeCoefficients()` to get new coefficients from the subclass,
    /// then atomically swaps the setup and resets delay buffers.
    func updateSampleRate(_ newRate: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        let oldRate = sampleRate
        guard newRate != sampleRate else { return }
        sampleRate = newRate

        guard let (coefficients, sectionCount) = recomputeCoefficients() else {
            // No state loaded — rate saved for future use
            return
        }

        let newSetup = UnsafeMutablePointer<Double>.allocate(capacity: sectionCount * 6)
        newSetup.initialize(from: coefficients, count: sectionCount * 6)

        // We inline the swap + reset here instead of calling swapSetup() + resetDelayBuffers()
        // because the ordering is critical: disable → swap → reset → re-enable must be atomic.
        // Calling them separately would leave a window where the audio thread could process
        // new coefficients with stale delay buffer state.
        let oldSetup = _eqSetup
        let wasEnabled = _isEnabled
        _isEnabled = false
        OSMemoryBarrier()

        _eqSetup = newSetup
        _eqSectionCount = sectionCount
        memset(delayBufferL, 0, delayBufferSize * MemoryLayout<SVFProcessorState>.size)
        memset(delayBufferR, 0, delayBufferSize * MemoryLayout<SVFProcessorState>.size)

        _isEnabled = wasEnabled
        OSMemoryBarrier()

        if let old = oldSetup {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                old.deallocate()
            }
        }

        logger.info("Sample rate: \(oldRate, format: .fixed(precision: 0))Hz → \(newRate, format: .fixed(precision: 0))Hz")
    }

    // MARK: - Subclass Hooks

    /// Override to provide coefficients for the current state at the current sample rate.
    /// Called during `updateSampleRate()`. Return `nil` if no state is loaded.
    ///
    /// - Returns: Tuple of (flat coefficient array in SVF format, number of SVF sections),
    ///   or `nil` to skip recomputation.
    func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        return nil
    }

    /// Override to apply pre-processing before the SVF cascade (e.g. preamp gain).
    /// Called after input is copied to output, before SVF processing. **Must be RT-safe.**
    ///
    /// Default implementation is a no-op.
    func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // No-op — subclasses override
    }

    // MARK: - Audio Processing (RT-safe)

    /// Process a single sample with SVF, using the specified state
    /// Processes a single section
    /// Updates the state before returning the sample
    func processSectionSample(input: Float, state: UnsafeMutablePointer<SVFProcessorState>, setup: UnsafePointer<Double>) -> Float {
        let a1 = setup[0]
        let a2 = setup[1]
        let a3 = setup[2]
        let m0 = setup[3]
        let m1 = setup[4]
        let m2 = setup[5]

        let v0 = Double(input)
        state.pointee.v3 = v0 - state.pointee.ic2eq
        state.pointee.v1 = a1 * state.pointee.ic1eq + a2 * state.pointee.v3
        state.pointee.v2 = state.pointee.ic2eq + a2 * state.pointee.ic1eq + a3 * state.pointee.v3
        state.pointee.ic1eq = 2.0 * state.pointee.v1 - state.pointee.ic1eq
        state.pointee.ic2eq = 2.0 * state.pointee.v2 - state.pointee.ic2eq

        let output = Float(m0 * v0 + m1 * state.pointee.v1 + m2 * state.pointee.v2)

        return output
    }

    /// Process a series of sections for the given sample
    /// Updates section states
    func processSample(input: Float, state: UnsafeMutablePointer<SVFProcessorState>, setup: UnsafePointer<Double>) -> Float {
        var output: Float = input
        for i in 0..<_eqSectionCount {
            output = processSectionSample(input: output, state: &state[i], setup: setup.advanced(by: i * 6))
        }
        return output
    }

    /// Process all sections for a buffer, in place
    func processBuffer(buffer: UnsafeMutablePointer<Float>, stride: Int, frameCount: Int, state: UnsafeMutablePointer<SVFProcessorState>, setup: UnsafePointer<Double>) {
        for i in 0..<frameCount {
            let output = processSample(input: buffer[i * stride], state: state, setup: setup)
            buffer[i * stride] = output
        }
    }

    /// Process stereo interleaved audio. RT-safe: no allocations, locks, ObjC, or I/O.
    /// Can process in-place (input == output).
    ///
    /// - Parameters:
    ///   - input: Input buffer (stereo interleaved Float32).
    ///   - output: Output buffer (stereo interleaved Float32).
    ///   - frameCount: Number of stereo frames (total samples / 2).
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        let enabled = _isEnabled
        let setup = _eqSetup

        // Bypass: copy input to output
        guard enabled, let setup = setup else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            return
        }

        // Copy input to output for in-place processing
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }

        // Subclass hook for pre-processing (e.g. preamp gain)
        preProcess(output: output, frameCount: frameCount)

        // Stereo SVF cascade: stride=2 for interleaved L/R data
        processBuffer(buffer: output, stride: 2, frameCount: frameCount, state: delayBufferL, setup: setup)
        processBuffer(buffer: output.advanced(by: 1), stride: 2, frameCount: frameCount, state: delayBufferR, setup: setup)

        // NaN safety net — pathological coefficients can produce NaN that
        // propagates through the entire downstream chain
        if output[0].isNaN || output[1].isNaN {
            memset(delayBufferL, 0, delayBufferSize * MemoryLayout<SVFProcessorState>.size)
            memset(delayBufferR, 0, delayBufferSize * MemoryLayout<SVFProcessorState>.size)
            memset(output, 0, frameCount * 2 * MemoryLayout<Float>.size)
        }
    }
}
