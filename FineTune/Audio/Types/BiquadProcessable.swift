// FineTune/Audio/Types/BiquadProcessable.swift

/// Protocol for RT-safe biquad audio processors.
///
/// Captures the read-only interface that audio callbacks use.
/// Concrete types should be used in the actual audio path to avoid
/// existential boxing overhead. This protocol enables testing and
/// future pipeline composition.
///
/// ## RT-Safety Contract
/// `process()` and `isEnabled` MUST be safe to call on CoreAudio's
/// HAL I/O thread: no allocations, locks, ObjC, logging, or I/O.
protocol BiquadProcessable: AnyObject {
    /// Whether processing is currently active (RT-safe atomic read).
    var isEnabled: Bool { get }

    /// Process stereo interleaved audio. RT-safe.
    /// Can process in-place (input == output).
    ///
    /// - Parameters:
    ///   - input: Input buffer (stereo interleaved Float32).
    ///   - output: Output buffer (stereo interleaved Float32).
    ///   - frameCount: Number of stereo frames (total samples / 2).
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int)

    /// Update the device sample rate. Call from main thread only.
    func updateSampleRate(_ newRate: Double)
}
