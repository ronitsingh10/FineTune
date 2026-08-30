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
    /// Failures known while the chain is built. This never changes after
    /// initialization, so it is safe for the render callback to ignore.
    private let initialFailedEntryIDs: Set<UUID>

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

    /// Snapshot intended for main-actor/controller/UI queries. Runtime render
    /// failures are represented by a scalar flag on each host; forming this set
    /// here keeps all collection work out of the CoreAudio callback.
    var failedEntryIDs: Set<UUID> {
        var failures = initialFailedEntryIDs
        for host in _hosts where host.renderFailed {
            failures.insert(host.entryID)
        }
        return failures
    }

    func host(for entryID: UUID) -> AUEffectHost? {
        _hosts.first { $0.entryID == entryID }
    }

    typealias HostFactory = (AUEffectChainEntry, Double, UInt32) -> AUEffectHost

    init(entries: [AUEffectChainEntry], sampleRate: Double, maxFrames: UInt32 = 4096, hostFactory: HostFactory? = nil) {
        self.entries = entries
        var hosts: [AUEffectHost] = []
        var failed = Set<UUID>()
        let makeHost = hostFactory ?? { entry, rate, frames in AUEffectHost(
                descriptor: entry.pluginDescriptor,
                entryID: entry.id,
                sampleRate: rate,
                maxFrames: frames,
                enabled: entry.isEnabled
            ) }
        for entry in entries {
            guard entry.isEnabled else { failed.insert(entry.id); continue }
            let host = makeHost(entry, sampleRate, maxFrames)
            if host.instantiate() {
                if let presetData = entry.presetData {
                    guard host.loadPreset(presetData) else { failed.insert(entry.id); continue }
                } else if let presetIndex = entry.selectedFactoryPresetIndex {
                    guard host.selectFactoryPreset(index: presetIndex) else { failed.insert(entry.id); continue }
                }
                hosts.append(host)
            } else {
                failed.insert(entry.id)
                logger.error("Failed to instantiate \(entry.pluginDescriptor.name), skipping")
            }
        }
        self.initialFailedEntryIDs = failed
        self._hosts = hosts
        self._hostCount = hosts.count

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
