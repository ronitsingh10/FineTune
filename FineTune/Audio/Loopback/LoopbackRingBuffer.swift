// FineTune/Audio/Loopback/LoopbackRingBuffer.swift
//
// Lock-free SPSC ring buffer over POSIX shared memory for lossless
// cross-process audio transfer to the FineTuneLoopback HAL plugin.
//
// Threading model:
//   - write() is called from CoreAudio's real-time HAL I/O thread (RT-safe)
//   - The HAL plugin reads from the other side via SharedMemoryReader
//   - Single producer, single consumer — no locks needed
//
// RT-SAFETY: write() must NEVER allocate, lock, log, or call ObjC.

import Foundation
import Darwin
import os

/// POSIX shared memory name — must match kFTLoopbackShmName in SharedTypes.h
private let kShmName = "/finetune_loopback"

/// Mirror of FTLoopbackSharedHeader from SharedTypes.h.
/// Layout must be identical — any mismatch breaks the binary protocol.
struct FTLoopbackSharedHeader {
    var writeHead: UInt64       // atomic, frames written (monotonic)
    var readHead: UInt64        // atomic, frames read (monotonic)
    var sampleRate: Float64     // e.g. 48000.0
    var channels: UInt32        // e.g. 2
    var isActive: UInt32        // 1 = connected, 0 = idle
    var bufferFrames: UInt32    // ring buffer capacity in frames
    var _padding: UInt32        // alignment
}

/// Lock-free single-producer, single-consumer ring buffer backed by POSIX shared memory.
///
/// The FineTune app acts as the producer (writes processed audio in the HAL I/O callback).
/// The FineTuneLoopback HAL plugin acts as the consumer (reads audio in its IO cycle).
///
/// Data flows through shared memory with zero copies beyond the initial memcpy:
///   App audio callback → memcpy → shared memory → memcpy → HAL plugin IO
///
/// The ring buffer uses monotonically increasing head counters (writeHead, readHead)
/// with modular indexing (`head % bufferFrames`) to avoid the full/empty ambiguity
/// problem. Available frames = writeHead - readHead.
final class LoopbackRingBuffer: @unchecked Sendable {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "LoopbackRingBuffer")

    /// Mapped shared memory region
    private var shmFD: Int32 = -1
    private var mappedBase: UnsafeMutableRawPointer?
    private var mappedSize: Int = 0

    /// Typed pointers into the mapped region (set during init, never change)
    private var header: UnsafeMutablePointer<FTLoopbackSharedHeader>?
    private var audioData: UnsafeMutablePointer<Float>?

    /// Cached configuration (immutable after init)
    let bufferFrames: UInt32
    let channels: UInt32
    let sampleRate: Float64

    /// Whether this buffer is currently active (set by activate/deactivate)
    private(set) var isActive: Bool = false

    /// Creates a new loopback ring buffer backed by POSIX shared memory.
    ///
    /// - Parameters:
    ///   - sampleRate: Audio sample rate (e.g. 48000.0)
    ///   - channels: Number of audio channels (e.g. 2 for stereo)
    ///   - bufferFrames: Ring buffer capacity in frames (default: 48000 = 1 second at 48kHz)
    init(sampleRate: Float64 = 48000.0, channels: UInt32 = 2, bufferFrames: UInt32 = 48000) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferFrames = bufferFrames

        let totalSize = MemoryLayout<FTLoopbackSharedHeader>.size
            + Int(bufferFrames) * Int(channels) * MemoryLayout<Float>.size

        // Always unlink any stale segment from a previous app run.
        // coreaudiod (HAL driver) may still hold an old mapping which prevents
        // ftruncate from resizing the segment (EINVAL). Unlinking removes the
        // name; existing mappings stay valid until unmapped, but our new
        // shm_open(O_CREAT) creates a brand-new segment.
        shm_unlink(kShmName)  // OK if it fails (segment doesn't exist)

        // Create fresh shared memory
        // O_CREAT | O_RDWR: create new segment for read+write
        // 0o666: readable/writable by all (HAL plugin runs as coreaudiod)
        let fd = ft_shm_open(kShmName, O_CREAT | O_RDWR, mode_t(0o666))
        guard fd >= 0 else {
            throw LoopbackError.shmOpenFailed(errno)
        }
        shmFD = fd

        // Set the size
        guard ftruncate(fd, off_t(totalSize)) == 0 else {
            let savedErrno = errno  // Save before close/unlink overwrite it
            Darwin.close(fd)
            shmFD = -1  // Prevent double-close in deinit
            shm_unlink(kShmName)
            throw LoopbackError.ftruncateFailed(savedErrno)
        }

        // Map into our address space
        let mapped = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED, let base = mapped else {
            let savedErrno = errno
            Darwin.close(fd)
            shmFD = -1
            shm_unlink(kShmName)
            throw LoopbackError.mmapFailed(savedErrno)
        }

        mappedBase = base
        mappedSize = totalSize

        // Set up typed pointers
        header = base.assumingMemoryBound(to: FTLoopbackSharedHeader.self)
        audioData = base.advanced(by: MemoryLayout<FTLoopbackSharedHeader>.size)
            .assumingMemoryBound(to: Float.self)

        // Initialize header
        header!.pointee.writeHead = 0
        header!.pointee.readHead = 0
        header!.pointee.sampleRate = sampleRate
        header!.pointee.channels = channels
        header!.pointee.isActive = 0
        header!.pointee.bufferFrames = bufferFrames
        header!.pointee._padding = 0

        // Zero the audio buffer
        memset(audioData!, 0, Int(bufferFrames) * Int(channels) * MemoryLayout<Float>.size)

        logger.info("Loopback ring buffer created: \(sampleRate)Hz, \(channels)ch, \(bufferFrames) frames (\(totalSize) bytes)")
    }

    deinit {
        deactivate()

        if let base = mappedBase {
            munmap(base, mappedSize)
        }
        if shmFD >= 0 {
            Darwin.close(shmFD)
            shm_unlink(kShmName)
        }

        logger.info("Loopback ring buffer destroyed")
    }

    /// Marks the ring buffer as active. The HAL plugin will start reading audio.
    func activate() {
        guard let header else { return }
        // Reset heads to start clean
        header.pointee.writeHead = 0
        header.pointee.readHead = 0
        header.pointee.sampleRate = sampleRate
        header.pointee.channels = channels
        OSMemoryBarrier() // Ensure all writes are visible before setting active flag
        header.pointee.isActive = 1
        isActive = true
        logger.info("Loopback activated")
    }

    /// Marks the ring buffer as inactive. The HAL plugin will output silence.
    func deactivate() {
        guard let header else { return }
        header.pointee.isActive = 0
        OSMemoryBarrier()
        isActive = false
        logger.info("Loopback deactivated")
    }

    // MARK: - RT-Safe Audio Write

    /// Writes audio frames to the ring buffer.
    ///
    /// **RT-SAFETY: This method is called from CoreAudio's real-time HAL I/O thread.**
    /// It performs ONLY:
    ///   - Pointer arithmetic
    ///   - memcpy
    ///   - Atomic-width stores (UInt64 on ARM64/x86-64)
    ///
    /// It does NOT: allocate, lock, log, call ObjC, or perform I/O.
    ///
    /// - Parameters:
    ///   - samples: Pointer to interleaved Float32 audio samples
    ///   - frameCount: Number of frames to write
    ///   - channels: Number of channels per frame (must match buffer configuration)
    @inline(__always)
    func write(_ samples: UnsafePointer<Float>, frameCount: Int, channels channelCount: Int) {
        guard let header, let audioData else { return }

        let bufFrames = Int(header.pointee.bufferFrames)
        let chans = Int(header.pointee.channels)
        guard bufFrames > 0, chans > 0 else { return }

        let currentWrite = header.pointee.writeHead
        let currentRead = header.pointee.readHead

        // Check available space (prevent overwriting unread data)
        let available = Int(Int64(bufFrames) - Int64(currentWrite - currentRead))
        let framesToWrite = min(frameCount, max(available, 0))
        guard framesToWrite > 0 else { return }

        let writePos = Int(currentWrite % UInt64(bufFrames))
        let samplesPerFrame = min(channelCount, chans)

        // Calculate how many frames fit before wrap-around
        let framesBeforeWrap = bufFrames - writePos
        let firstChunkFrames = min(framesToWrite, framesBeforeWrap)
        let secondChunkFrames = framesToWrite - firstChunkFrames

        if channelCount == chans {
            // Fast path: channel counts match, direct memcpy
            let firstChunkSamples = firstChunkFrames * chans
            memcpy(
                audioData.advanced(by: writePos * chans),
                samples,
                firstChunkSamples * MemoryLayout<Float>.size
            )

            if secondChunkFrames > 0 {
                let secondChunkSamples = secondChunkFrames * chans
                memcpy(
                    audioData,
                    samples.advanced(by: firstChunkSamples),
                    secondChunkSamples * MemoryLayout<Float>.size
                )
            }
        } else {
            // Slow path: channel count mismatch, copy per-frame
            for frame in 0..<framesToWrite {
                let ringPos = ((writePos + frame) % bufFrames) * chans
                let srcPos = frame * channelCount
                for ch in 0..<samplesPerFrame {
                    audioData[ringPos + ch] = samples[srcPos + ch]
                }
                // Zero extra channels if ring has more than source
                for ch in samplesPerFrame..<chans {
                    audioData[ringPos + ch] = 0
                }
            }
        }

        // Memory barrier: ensure all audio data writes are visible before
        // updating writeHead. The consumer reads writeHead first, then reads
        // audio data — this ordering guarantees it sees complete frames.
        OSMemoryBarrier()
        header.pointee.writeHead = currentWrite + UInt64(framesToWrite)
    }
}

// MARK: - Errors

enum LoopbackError: Error {
    case shmOpenFailed(Int32)
    case ftruncateFailed(Int32)
    case mmapFailed(Int32)
    case driverNotInstalled

    var localizedDescription: String {
        switch self {
        case .shmOpenFailed(let err):
            return "Failed to create shared memory: \(String(cString: strerror(err)))"
        case .ftruncateFailed(let err):
            return "Failed to resize shared memory: \(String(cString: strerror(err)))"
        case .mmapFailed(let err):
            return "Failed to map shared memory: \(String(cString: strerror(err)))"
        case .driverNotInstalled:
            return "FineTune Loopback driver is not installed"
        }
    }
}
