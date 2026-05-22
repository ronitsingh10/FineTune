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
private let gMaxDeviceSlots = 64

// AU plugin crash tracking — fixed-size buffer of FNV-1a hashes of plugin IDs
private nonisolated(unsafe) var gPluginHashSlots: UnsafeMutablePointer<UInt64>?
private nonisolated(unsafe) var gPluginHashCount: Int32 = 0
private nonisolated(unsafe) var gPluginHashLock = os_unfair_lock()
private let gMaxPluginSlots = 128

// File path for crash plugin data (resolved once at install)
private nonisolated(unsafe) var gCrashPluginFilePath: UnsafePointer<CChar>?

// MARK: - Crash Signal Handler

/// C-compatible crash signal handler. Destroys all tracked aggregate devices
/// via IPC to coreaudiod, then re-raises the signal for default crash behavior.
///
/// ASYNC-SIGNAL-SAFETY: AudioHardwareDestroyAggregateDevice is a Mach IPC call
/// to coreaudiod and doesn't depend on in-process heap state. The fixed-size C
/// buffer avoids any Swift or libc heap operations.
private func crashSignalHandler(_ sig: Int32) {
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

    // Write active plugin hashes to crash file (POSIX I/O — async-signal-safe)
    if let path = gCrashPluginFilePath, let hashSlots = gPluginHashSlots {
        let hashCount = Int(gPluginHashCount)
        if hashCount > 0 {
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                let byteCount = hashCount * MemoryLayout<UInt64>.size
                _ = write(fd, hashSlots, byteCount)
                close(fd)
            }
        }
    }

    // Re-raise with default handler for normal crash behavior (crash report, core dump)
    raise(sig)
}

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "CrashGuard")

// MARK: - Public API

/// Tracks live aggregate device IDs and destroys them on crash signals
/// (SIGABRT, SIGSEGV, SIGBUS, SIGTRAP).
///
/// Uses a fixed-size C buffer (not Swift collections) so the signal handler
/// only touches async-signal-safe memory.
enum CrashGuard {
    /// Allocates the tracking buffer and installs crash signal handlers.
    /// Call once on app startup, before creating any taps.
    static func install() {
        let buffer = UnsafeMutablePointer<AudioObjectID>.allocate(capacity: gMaxDeviceSlots)
        buffer.initialize(repeating: AudioObjectID(kAudioObjectUnknown), count: gMaxDeviceSlots)
        gDeviceSlots = buffer

        let pluginBuffer = UnsafeMutablePointer<UInt64>.allocate(capacity: gMaxPluginSlots)
        pluginBuffer.initialize(repeating: 0, count: gMaxPluginSlots)
        gPluginHashSlots = pluginBuffer

        // Resolve crash file path once (async-signal-safe read later)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FineTune")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent(".au-crash-plugins").path
        if let cStr = (filePath as NSString).utf8String {
            gCrashPluginFilePath = UnsafePointer(strdup(cStr))
        }

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

    // MARK: - AU Plugin Tracking

    /// FNV-1a hash for async-signal-safe plugin ID hashing
    static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    static func trackPlugin(_ pluginID: String) {
        let hash = fnv1aHash(pluginID)
        os_unfair_lock_lock(&gPluginHashLock)
        defer { os_unfair_lock_unlock(&gPluginHashLock) }
        guard let slots = gPluginHashSlots else { return }
        let n = Int(gPluginHashCount)
        // Deduplicate
        for i in 0..<n {
            if slots[i] == hash { return }
        }
        guard n < gMaxPluginSlots else {
            logger.error("Plugin slot limit (\(gMaxPluginSlots)) reached")
            return
        }
        slots[n] = hash
        gPluginHashCount += 1
    }

    static func untrackPlugin(_ pluginID: String) {
        let hash = fnv1aHash(pluginID)
        os_unfair_lock_lock(&gPluginHashLock)
        defer { os_unfair_lock_unlock(&gPluginHashLock) }
        guard let slots = gPluginHashSlots else { return }
        let n = Int(gPluginHashCount)
        for i in 0..<n {
            if slots[i] == hash {
                let lastIdx = n - 1
                slots[i] = slots[lastIdx]
                slots[lastIdx] = 0
                gPluginHashCount -= 1
                return
            }
        }
    }

    /// Reads crash plugin hashes written by the signal handler on previous crash.
    /// Returns matching plugin IDs from the provided known set, then deletes the file.
    static func readAndClearCrashPlugins(knownPluginIDs: [String]) -> Set<String> {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let filePath = appSupport.appendingPathComponent("FineTune/.au-crash-plugins")
        guard let data = try? Data(contentsOf: filePath) else { return [] }
        try? FileManager.default.removeItem(at: filePath)

        let hashCount = data.count / MemoryLayout<UInt64>.size
        guard hashCount > 0 else { return [] }

        var crashHashes = Set<UInt64>()
        data.withUnsafeBytes { buffer in
            let hashes = buffer.bindMemory(to: UInt64.self)
            for i in 0..<hashCount {
                crashHashes.insert(hashes[i])
            }
        }

        var matched = Set<String>()
        for pluginID in knownPluginIDs {
            if crashHashes.contains(fnv1aHash(pluginID)) {
                matched.insert(pluginID)
            }
        }
        return matched
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
