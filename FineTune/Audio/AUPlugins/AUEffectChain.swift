// FineTune/Audio/AUPlugins/AUEffectChain.swift
import Foundation
import os

/// Immutable ordered chain of AU effect hosts.
///
/// When the chain changes (add/remove/reorder), build a new `AUEffectChain` and
/// atomically swap the pointer in `ProcessTapController`, then defer-destroy the
/// old chain after 500ms. Same pattern as `LoudnessEqualizer`.
///
/// ## RT-Safety
/// `process()` runs on CoreAudio's HAL I/O thread. Reads `_hosts`/`_hostCount`/`_isBypassed`
/// which are set once at init (except bypass, toggled from main thread).
final class AUEffectChain: @unchecked Sendable {

    let entries: [AUEffectChainEntry]
    let failedEntryIDs: Set<UUID>

    private let _hosts: [AUEffectHost]
    private let _hostCount: Int
    private nonisolated(unsafe) var _isBypassed: Bool = false

    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUEffectChain")

    var isBypassed: Bool { _isBypassed }

    var maxTailTime: Double {
        var maxTail: Double = 0
        for host in _hosts where host.isEnabled {
            if host.tailTimeSeconds > maxTail {
                maxTail = host.tailTimeSeconds
            }
        }
        return maxTail
    }

    var hosts: [AUEffectHost] { _hosts }

    func host(for entryID: UUID) -> AUEffectHost? {
        _hosts.first { $0.entryID == entryID }
    }

    init(entries: [AUEffectChainEntry], sampleRate: Double, maxFrames: UInt32 = 4096) {
        self.entries = entries
        var hosts: [AUEffectHost] = []
        var failed = Set<UUID>()
        for entry in entries {
            let host = AUEffectHost(
                descriptor: entry.pluginDescriptor,
                entryID: entry.id,
                sampleRate: sampleRate,
                maxFrames: maxFrames,
                enabled: entry.isEnabled
            )
            if host.instantiate() {
                if let presetData = entry.presetData {
                    _ = host.loadPreset(presetData)
                } else if let presetIndex = entry.selectedFactoryPresetIndex {
                    _ = host.selectFactoryPreset(index: presetIndex)
                }
                hosts.append(host)
            } else {
                failed.insert(entry.id)
                logger.error("Failed to instantiate \(entry.pluginDescriptor.name), skipping")
            }
        }
        self.failedEntryIDs = failed
        self._hosts = hosts
        self._hostCount = hosts.count

        for host in hosts {
            CrashGuard.trackPlugin(host.descriptor.id)
        }

        logger.info("Created AU effect chain with \(hosts.count)/\(entries.count) plugins at \(sampleRate)Hz")
    }

    // MARK: - Bypass

    func setBypassed(_ bypassed: Bool) {
        _isBypassed = bypassed
    }

    // MARK: - RT-Safe Processing

    /// Process interleaved stereo samples through the entire AU chain in-place.
    @inline(__always)
    func processInterleaved(samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !_isBypassed else { return }
        let count = _hostCount
        for i in 0..<count {
            _hosts[i].renderInterleaved(samples: samples, frameCount: frameCount)
        }
    }
}
