// FineTune/Audio/CrossfadeState.swift
import Foundation

/// State machine phases for device switching crossfade.
enum CrossfadePhase: Int, Equatable {
    case idle = 0
    case warmingUp = 1
    case crossfading = 2
}

/// RT-safe crossfade state container.
/// All fields are designed for lock-free access from audio callbacks.
///
/// **Threading model:**
/// - Main thread writes via `beginCrossfade()`, `beginCrossfading()`, `complete()`
/// - Secondary audio callback writes via `updateProgress(samples:)` (single-writer)
/// - Both audio callbacks read `phase`, `primaryMultiplier`, `secondaryMultiplier`
///
/// **Memory ordering:** Uses aligned Float/Int reads which are atomic on Apple platforms
/// (ARM64/x86-64). `OSMemoryBarrier()` ensures cross-core visibility at phase transitions.
struct CrossfadeState: @unchecked Sendable {
    /// Current crossfade progress (0 = full primary, 1 = full secondary)
    nonisolated(unsafe) var progress: Float = 0

    /// RT-safe phase storage (Int for atomic reads on audio thread)
    nonisolated(unsafe) private var _phaseRawValue: Int = 0

    /// Current crossfade phase
    var phase: CrossfadePhase {
        get { CrossfadePhase(rawValue: _phaseRawValue) ?? .idle }
        set { _phaseRawValue = newValue.rawValue }
    }

    /// Backward-compatible: true when warmingUp OR crossfading
    var isActive: Bool {
        _phaseRawValue != CrossfadePhase.idle.rawValue
    }

    /// Sample count from secondary callback (drives crossfade timing)
    nonisolated(unsafe) var secondarySampleCount: Int64 = 0

    /// Total samples for the crossfade duration
    nonisolated(unsafe) var totalSamples: Int64 = 0

    /// Samples processed by secondary (for warmup tracking)
    nonisolated(unsafe) var secondarySamplesProcessed: Int = 0

    /// Minimum samples secondary must process before destroying primary
    static let minimumWarmupSamples: Int = 2048  // ~43ms at 48kHz

    init() {}

    // MARK: - Phase Transitions (called from main thread)

    /// Resets all state and enters warmingUp phase without setting totalSamples.
    /// Call before secondary tap creation so audio callbacks see correct phase.
    /// Set `totalSamples` separately after reading the new device's sample rate.
    mutating func beginWarmup() {
        progress = 0
        secondarySampleCount = 0
        secondarySamplesProcessed = 0
        totalSamples = 0
        OSMemoryBarrier()    // Flush data stores before publishing phase
        phase = .warmingUp
    }

    /// Resets all state and enters warmingUp phase.
    /// Call when secondary tap is created and starting to receive audio.
    mutating func beginCrossfade(at sampleRate: Double) {
        progress = 0
        secondarySampleCount = 0
        secondarySamplesProcessed = 0
        totalSamples = CrossfadeConfig.totalSamples(at: sampleRate)
        OSMemoryBarrier()    // Flush data stores before publishing phase
        phase = .warmingUp
    }

    /// Transitions from warmingUp to crossfading.
    /// Call after warmup is confirmed (secondary has processed enough samples).
    mutating func beginCrossfading() {
        secondarySampleCount = 0
        progress = 0
        OSMemoryBarrier()    // Flush data stores before publishing phase
        phase = .crossfading
    }

    /// Completes the crossfade and resets all state to idle.
    mutating func complete() {
        progress = 0
        secondarySampleCount = 0
        secondarySamplesProcessed = 0
        totalSamples = 0
        OSMemoryBarrier()    // Flush data stores before publishing phase
        phase = .idle
    }

    // MARK: - Audio Thread Access

    /// Updates progress based on samples processed.
    /// **Called only from the secondary audio callback** (single-writer pattern).
    ///
    /// - Parameter samples: Number of samples just processed this buffer
    /// - Returns: New progress value (0.0 to 1.0)
    @inline(__always)
    mutating func updateProgress(samples: Int) -> Float {
        secondarySamplesProcessed += samples
        if phase == .crossfading {
            secondarySampleCount += Int64(samples)
            progress = min(1.0, Float(secondarySampleCount) / Float(max(1, totalSamples)))
        }
        return progress
    }

    /// Checks if warmup is complete (enough samples processed by secondary)
    var isWarmupComplete: Bool {
        secondarySamplesProcessed >= Self.minimumWarmupSamples
    }

    /// Checks if the crossfade animation is complete (progress reached 1.0)
    var isCrossfadeComplete: Bool {
        progress >= 1.0
    }

    /// Equal-power fade-out multiplier for primary tap.
    /// cos(0) = 1.0 (full volume), cos(pi/2) = 0.0 (silent)
    @inline(__always)
    var primaryMultiplier: Float {
        switch phase {
        case .idle:
            return progress >= 1.0 ? 0.0 : 1.0
        case .warmingUp:
            return 1.0
        case .crossfading:
            return cos(progress * .pi / 2.0)
        }
    }

    /// Equal-power fade-in multiplier for secondary tap.
    /// sin(0) = 0.0 (silent), sin(pi/2) = 1.0 (full volume)
    @inline(__always)
    var secondaryMultiplier: Float {
        switch phase {
        case .idle:
            return 1.0  // After promotion, full volume
        case .warmingUp:
            return 0.0  // Muted during warmup
        case .crossfading:
            return sin(progress * .pi / 2.0)
        }
    }
}
