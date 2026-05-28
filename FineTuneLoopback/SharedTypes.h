// FineTuneLoopback/SharedTypes.h
// Shared memory layout for FineTune ↔ HAL plugin audio transfer.
//
// This header defines the binary protocol between the FineTune app (producer)
// and the FineTuneLoopback HAL plugin (consumer). Both sides must agree on
// this layout exactly — any mismatch causes silent corruption or crashes.
//
// Threading model:
//   Producer (FineTune audio callback): writes audio data, updates writeHead
//   Consumer (HAL plugin IO thread):   reads audio data, updates readHead
//   Single-producer, single-consumer — no locks needed, only atomics on heads.

#ifndef FINETUNE_LOOPBACK_SHARED_TYPES_H
#define FINETUNE_LOOPBACK_SHARED_TYPES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// POSIX shared memory name (used with shm_open)
#define kFTLoopbackShmName "/finetune_loopback"

// Default configuration — these must match the driver defaults in FTLoopbackDriver.h
#define kFTLoopbackDefaultBufferFrames  48000   // 1 second at 48kHz (ring buffer capacity)
#define kFTLoopbackDefaultChannels      2
#define kFTLoopbackDefaultSampleRate    44100.0  // M2: Must match kFTDefaultSampleRate in driver

/// Shared memory header — sits at the start of the mapped region.
/// All fields are naturally aligned for atomic access on ARM64/x86-64.
///
/// Memory layout:
///   [FTLoopbackSharedHeader]  (48 bytes)
///   [float audio data]       (bufferFrames * channels * sizeof(float))
typedef struct {
    /// Monotonically increasing frame counter written by the producer.
    /// Consumer reads this atomically to determine available frames.
    /// Ring buffer write position = writeHead % bufferFrames
    volatile uint64_t writeHead;        // offset 0

    /// Monotonically increasing frame counter written by the consumer.
    /// Producer reads this atomically to determine free space.
    /// Ring buffer read position = readHead % bufferFrames
    volatile uint64_t readHead;         // offset 8

    /// Sample rate of the audio data (e.g. 44100.0, 48000.0, 96000.0).
    /// Set by producer when activating, read by consumer to configure streams.
    volatile double sampleRate;         // offset 16

    /// Number of audio channels (e.g. 2 for stereo).
    /// Set by producer when activating.
    volatile uint32_t channels;         // offset 24

    /// 1 = producer is connected and writing audio, 0 = idle/disconnected.
    /// Consumer outputs silence when this is 0.
    volatile uint32_t isActive;         // offset 28

    /// Total capacity of the ring buffer in frames.
    /// Set by producer on creation, immutable after that.
    volatile uint32_t bufferFrames;     // offset 32

    /// Reserved for future use, ensures 8-byte alignment of audio data.
    uint32_t _padding;                  // offset 36

    /// mach_absolute_time() of the most recent write() call.
    /// Updated atomically by the producer after writing audio data.
    /// The HAL driver uses this to derive its clock from the producer's
    /// clock, eliminating drift between independent clocks.
    volatile uint64_t hostTime;         // offset 40
} FTLoopbackSharedHeader;               // total: 48 bytes

// Compile-time size check
_Static_assert(sizeof(FTLoopbackSharedHeader) == 48,
    "FTLoopbackSharedHeader size mismatch — binary protocol broken");

/// Returns the total shared memory size needed for a given configuration.
static inline size_t FTLoopbackShmSize(uint32_t bufferFrames, uint32_t channels) {
    return sizeof(FTLoopbackSharedHeader) + (size_t)bufferFrames * channels * sizeof(float);
}

/// Returns a pointer to the start of the audio ring buffer data.
static inline float* FTLoopbackAudioData(FTLoopbackSharedHeader* header) {
    return (float*)((uint8_t*)header + sizeof(FTLoopbackSharedHeader));
}

/// Returns a const pointer to the start of the audio ring buffer data.
static inline const float* FTLoopbackAudioDataConst(const FTLoopbackSharedHeader* header) {
    return (const float*)((const uint8_t*)header + sizeof(FTLoopbackSharedHeader));
}

#ifdef __cplusplus
}
#endif

#endif // FINETUNE_LOOPBACK_SHARED_TYPES_H
