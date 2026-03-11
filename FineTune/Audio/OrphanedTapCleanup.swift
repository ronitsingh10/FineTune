// FineTune/Audio/OrphanedTapCleanup.swift
import AudioToolbox
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "OrphanedTapCleanup")

/// Scans CoreAudio for orphaned FineTune aggregate devices and destroys them.
/// Orphans occur when FineTune crashes or is force-killed (`kill -9`), leaving
/// aggregate devices with `.mutedWhenTapped` process taps that silently mute apps.
enum OrphanedTapCleanup {
    /// Destroys any aggregate devices named "FineTune-*" left over from a previous session.
    /// Call on startup before creating any new taps.
    static func destroyOrphanedDevices() {
        let devices: [AudioDeviceID]
        do {
            devices = try AudioObjectID.readDeviceList()
        } catch {
            logger.error("[CLEANUP] Failed to read device list: \(error.localizedDescription)")
            return
        }

        var destroyedCount = 0

        for device in devices {
            let transportType = device.readTransportType()
            guard transportType == .aggregate else { continue }

            guard let name = try? device.readDeviceName(),
                  name.hasPrefix("FineTune-") else { continue }

            let err = AudioHardwareDestroyAggregateDevice(device)
            if err == noErr {
                destroyedCount += 1
                logger.info("[CLEANUP] Destroyed orphaned aggregate device: \(name) (ID \(device))")
            } else {
                logger.error("[CLEANUP] Failed to destroy \(name) (ID \(device)): OSStatus \(err)")
            }
        }

        if destroyedCount == 0 {
            logger.info("[CLEANUP] No orphaned FineTune devices found")
        } else {
            logger.info("[CLEANUP] Destroyed \(destroyedCount) orphaned device(s)")
        }
    }
}
