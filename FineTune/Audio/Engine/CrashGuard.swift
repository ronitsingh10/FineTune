// FineTune/Audio/Engine/CrashGuard.swift
import AudioToolbox
import os

// MARK: - Signal-Safe Globals

// Fixed-size buffer for async-signal-safe access from crash handler.
// Allocated once at install(), never freed (process-lifetime).
// Written from main/utility threads under lock, read from signal handler (single execution).
private nonisolated(unsafe) var gDeviceSlots: UnsafeMutablePointer<AudioObjectID>?
private nonisolated(unsafe) var gDeviceCount: Int32 = 0
private nonisolated(unsafe) var gDeviceLock = os_unfair_lock()
private nonisolated let gMaxDeviceSlots = 64
private nonisolated(unsafe) var gPluginHashSlots: UnsafeMutablePointer<UInt64>?
private nonisolated(unsafe) var gPluginRefCountSlots: UnsafeMutablePointer<UInt32>?
private nonisolated(unsafe) var gPluginHashCount: Int32 = 0
private nonisolated(unsafe) var gPluginHashLock = os_unfair_lock()
private nonisolated let gMaxPluginSlots = 128
private nonisolated(unsafe) var gCrashPluginFilePath: UnsafePointer<CChar>?

// MARK: - Crash Signal Handler

/// C-compatible crash signal handler. Destroys all tracked aggregate devices
/// via IPC to coreaudiod, then re-raises the signal for default crash behavior.
///
/// ASYNC-SIGNAL-SAFETY: AudioHardwareDestroyAggregateDevice is a Mach IPC call
/// to coreaudiod and doesn't depend on in-process heap state. The fixed-size C
/// buffer avoids any Swift or libc heap operations.
private nonisolated func crashSignalHandler(_ sig: Int32) {
    // Reset to default FIRST to prevent infinite recursion if cleanup itself crashes
    signal(sig, SIG_DFL)

    if let slots = gDeviceSlots {
        let n = Int(gDeviceCount)
        for i in 0..<n {
            let deviceID = slots[i]
            if deviceID != AudioObjectID(kAudioObjectUnknown) {
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    if let path = gCrashPluginFilePath, let hashes = gPluginHashSlots, gPluginHashCount > 0 {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            _ = write(fd, hashes, Int(gPluginHashCount) * MemoryLayout<UInt64>.size)
            close(fd)
        }
    }

    // Re-raise with default handler for normal crash behavior (crash report, core dump)
    raise(sig)
}

private nonisolated let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "CrashGuard")

// MARK: - Public API

/// Tracks live aggregate device IDs and destroys them on crash signals
/// (SIGABRT, SIGSEGV, SIGBUS, SIGTRAP).
///
/// Uses a fixed-size C buffer (not Swift collections) so the signal handler
/// only touches async-signal-safe memory.
nonisolated enum CrashGuard {
    /// Allocates the tracking buffer and installs crash signal handlers.
    /// Call once on app startup, before creating any taps.
    static func install() {
        let buffer = UnsafeMutablePointer<AudioObjectID>.allocate(capacity: gMaxDeviceSlots)
        buffer.initialize(repeating: AudioObjectID(kAudioObjectUnknown), count: gMaxDeviceSlots)
        gDeviceSlots = buffer
        let pluginBuffer = UnsafeMutablePointer<UInt64>.allocate(capacity: gMaxPluginSlots)
        pluginBuffer.initialize(repeating: 0, count: gMaxPluginSlots)
        gPluginHashSlots = pluginBuffer
        let pluginRefBuffer = UnsafeMutablePointer<UInt32>.allocate(capacity: gMaxPluginSlots)
        pluginRefBuffer.initialize(repeating: 0, count: gMaxPluginSlots)
        gPluginRefCountSlots = pluginRefBuffer
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("FineTune")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        gCrashPluginFilePath = UnsafePointer(strdup(directory.appendingPathComponent(".au-crash-plugins").path))

        signal(SIGABRT, crashSignalHandler)
        signal(SIGSEGV, crashSignalHandler)
        signal(SIGBUS, crashSignalHandler)
        signal(SIGTRAP, crashSignalHandler)
    }

    /// Registers an aggregate device for crash-safe cleanup.
    /// Call immediately after successful `AudioHardwareCreateAggregateDevice`.
    static func trackDevice(_ deviceID: AudioObjectID) {
        os_unfair_lock_lock(&gDeviceLock)
        guard let slots = gDeviceSlots else {
            os_unfair_lock_unlock(&gDeviceLock)
            return
        }
        let idx = Int(gDeviceCount)
        guard idx < gMaxDeviceSlots else {
            os_unfair_lock_unlock(&gDeviceLock)
            logger.error("Slot limit (\(gMaxDeviceSlots)) reached — device \(deviceID) not tracked for crash cleanup")
            return
        }
        slots[idx] = deviceID
        gDeviceCount += 1
        os_unfair_lock_unlock(&gDeviceLock)
    }

    static func trackPlugin(_ pluginID: String) {
        let hash = fnv1aHash(pluginID)
        os_unfair_lock_lock(&gPluginHashLock)
        defer { os_unfair_lock_unlock(&gPluginHashLock) }
        guard let slots = gPluginHashSlots, let refCounts = gPluginRefCountSlots else { return }
        let count = Int(gPluginHashCount)
        for index in 0..<count where slots[index] == hash { refCounts[index] &+= 1; return }
        guard count < gMaxPluginSlots else { return }
        slots[count] = hash
        refCounts[count] = 1
        gPluginHashCount += 1
    }

    static func untrackPlugin(_ pluginID: String) {
        let hash = fnv1aHash(pluginID)
        os_unfair_lock_lock(&gPluginHashLock)
        defer { os_unfair_lock_unlock(&gPluginHashLock) }
        guard let slots = gPluginHashSlots, let refCounts = gPluginRefCountSlots else { return }
        let count = Int(gPluginHashCount)
        for index in 0..<count where slots[index] == hash {
            if refCounts[index] > 1 { refCounts[index] -= 1; return }
            let last = count - 1
            slots[index] = slots[last]
            refCounts[index] = refCounts[last]
            slots[last] = 0
            refCounts[last] = 0
            gPluginHashCount -= 1
            return
        }
    }

    static func trackedReferenceCountForTesting(descriptorHash: UInt64) -> UInt32 {
        os_unfair_lock_lock(&gPluginHashLock)
        defer { os_unfair_lock_unlock(&gPluginHashLock) }
        guard let slots = gPluginHashSlots, let refs = gPluginRefCountSlots else { return 0 }
        for index in 0..<Int(gPluginHashCount) where slots[index] == descriptorHash { return refs[index] }
        return 0
    }

    static func readAndClearCrashPlugins(knownPluginIDs: [String]) -> Set<String> {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FineTune/.au-crash-plugins")
        guard let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        let crashHashes = data.withUnsafeBytes { Set($0.bindMemory(to: UInt64.self)) }
        return Set(knownPluginIDs.filter { crashHashes.contains(fnv1aHash($0)) })
    }

    static func fnv1aHash(_ string: String) -> UInt64 {
        string.utf8.reduce(14695981039346656037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }

    /// Removes an aggregate device from crash-safe tracking.
    /// Call immediately before `AudioHardwareDestroyAggregateDevice`.
    static func untrackDevice(_ deviceID: AudioObjectID) {
        os_unfair_lock_lock(&gDeviceLock)
        defer { os_unfair_lock_unlock(&gDeviceLock) }
        guard let slots = gDeviceSlots else { return }
        let n = Int(gDeviceCount)
        for i in 0..<n {
            if slots[i] == deviceID {
                let lastIdx = n - 1
                slots[i] = slots[lastIdx]
                slots[lastIdx] = AudioObjectID(kAudioObjectUnknown)
                gDeviceCount -= 1
                return
            }
        }
    }
}
