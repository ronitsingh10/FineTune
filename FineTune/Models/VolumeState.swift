// FineTune/Models/VolumeState.swift
import Foundation

/// Device selection mode for an app's audio output
enum DeviceSelectionMode: String, Codable, Equatable {
    case single  // Route to one device (default)
    case multi   // Route to multiple devices simultaneously
}

/// Consolidated state for a single app's audio settings
struct AppAudioState {
    var volume: Float
    var muted: Bool
    var persistenceIdentifier: String
    var deviceSelectionMode: DeviceSelectionMode = .single
    var selectedDeviceUIDs: Set<String> = []  // Used in multi mode
    var selectedDeviceUIDOrder: [String] = []  // Preserves user order for multi mode
}

@Observable
@MainActor
final class VolumeState {
    /// Single source of truth for per-app audio state
    private var states: [pid_t: AppAudioState] = [:]
    private let settingsManager: SettingsManager?

    init(settingsManager: SettingsManager? = nil) {
        self.settingsManager = settingsManager
    }

    // MARK: - Volume

    func getVolume(for pid: pid_t) -> Float {
        states[pid]?.volume ?? (settingsManager?.appSettings.defaultNewAppVolume ?? 1.0)
    }

    func setVolume(for pid: pid_t, to volume: Float, identifier: String? = nil) {
        if var state = states[pid] {
            state.volume = volume
            if let identifier = identifier {
                state.persistenceIdentifier = identifier
            }
            states[pid] = state
            settingsManager?.setVolume(for: state.persistenceIdentifier, to: volume)
        } else if let identifier = identifier {
            states[pid] = AppAudioState(volume: volume, muted: false, persistenceIdentifier: identifier)
            settingsManager?.setVolume(for: identifier, to: volume)
        }
        // If no identifier provided and no existing state, volume is not persisted
    }

    func loadSavedVolume(for pid: pid_t, identifier: String) -> Float? {
        ensureState(for: pid, identifier: identifier)
        if let saved = settingsManager?.getVolume(for: identifier) {
            states[pid]?.volume = saved
            return saved
        }
        return nil
    }

    // MARK: - Mute State

    func getMute(for pid: pid_t) -> Bool {
        states[pid]?.muted ?? false
    }

    func setMute(for pid: pid_t, to muted: Bool, identifier: String? = nil) {
        if var state = states[pid] {
            state.muted = muted
            if let identifier = identifier {
                state.persistenceIdentifier = identifier
            }
            states[pid] = state
            settingsManager?.setMute(for: state.persistenceIdentifier, to: muted)
        } else if let identifier = identifier {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            states[pid] = AppAudioState(volume: defaultVolume, muted: muted, persistenceIdentifier: identifier)
            settingsManager?.setMute(for: identifier, to: muted)
        }
        // If no identifier provided and no existing state, mute is not persisted
    }

    func loadSavedMute(for pid: pid_t, identifier: String) -> Bool? {
        ensureState(for: pid, identifier: identifier)
        if let saved = settingsManager?.getMute(for: identifier) {
            states[pid]?.muted = saved
            return saved
        }
        return nil
    }

    // MARK: - Device Selection Mode

    func getDeviceSelectionMode(for pid: pid_t) -> DeviceSelectionMode {
        states[pid]?.deviceSelectionMode ?? .single
    }

    func setDeviceSelectionMode(for pid: pid_t, to mode: DeviceSelectionMode, identifier: String? = nil) {
        if var state = states[pid] {
            state.deviceSelectionMode = mode
            if let identifier = identifier {
                state.persistenceIdentifier = identifier
            }
            states[pid] = state
            settingsManager?.setDeviceSelectionMode(for: state.persistenceIdentifier, to: mode)
        } else if let identifier = identifier {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            var newState = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
            newState.deviceSelectionMode = mode
            states[pid] = newState
            settingsManager?.setDeviceSelectionMode(for: identifier, to: mode)
        }
    }

    func loadSavedDeviceSelectionMode(for pid: pid_t, identifier: String) -> DeviceSelectionMode? {
        ensureState(for: pid, identifier: identifier)
        if let saved = settingsManager?.getDeviceSelectionMode(for: identifier) {
            states[pid]?.deviceSelectionMode = saved
            return saved
        }
        return nil
    }

    // MARK: - Selected Device UIDs (Multi Mode)

    func getSelectedDeviceUIDs(for pid: pid_t) -> Set<String> {
        states[pid]?.selectedDeviceUIDs ?? []
    }

    func getSelectedDeviceUIDOrder(for pid: pid_t) -> [String] {
        guard let state = states[pid] else { return [] }
        return Self.normalizedUIDOrder(state.selectedDeviceUIDOrder, selectedUIDs: state.selectedDeviceUIDs)
    }

    func setSelectedDeviceUIDs(
        for pid: pid_t,
        to uids: Set<String>,
        orderedUIDs: [String]? = nil,
        identifier: String? = nil
    ) {
        if var state = states[pid] {
            state.selectedDeviceUIDs = uids
            state.selectedDeviceUIDOrder = Self.normalizedUIDOrder(
                orderedUIDs ?? state.selectedDeviceUIDOrder,
                selectedUIDs: uids
            )
            if let identifier = identifier {
                state.persistenceIdentifier = identifier
            }
            states[pid] = state
            settingsManager?.setSelectedDeviceUIDOrder(
                for: state.persistenceIdentifier,
                to: state.selectedDeviceUIDOrder
            )
        } else if let identifier = identifier {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            var newState = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
            newState.selectedDeviceUIDs = uids
            newState.selectedDeviceUIDOrder = Self.normalizedUIDOrder(orderedUIDs ?? [], selectedUIDs: uids)
            states[pid] = newState
            settingsManager?.setSelectedDeviceUIDOrder(for: identifier, to: newState.selectedDeviceUIDOrder)
        }
    }

    func loadSavedSelectedDeviceUIDs(for pid: pid_t, identifier: String) -> Set<String>? {
        ensureState(for: pid, identifier: identifier)
        if let savedOrder = settingsManager?.getSelectedDeviceUIDOrder(for: identifier) {
            let savedSet = Set(savedOrder)
            states[pid]?.selectedDeviceUIDs = savedSet
            states[pid]?.selectedDeviceUIDOrder = savedOrder
            return savedSet
        }
        return nil
    }

    func loadSavedSelectedDeviceUIDOrder(for pid: pid_t, identifier: String) -> [String]? {
        ensureState(for: pid, identifier: identifier)
        if let savedOrder = settingsManager?.getSelectedDeviceUIDOrder(for: identifier) {
            let savedSet = Set(savedOrder)
            states[pid]?.selectedDeviceUIDs = savedSet
            states[pid]?.selectedDeviceUIDOrder = savedOrder
            return savedOrder
        }
        return nil
    }

    // MARK: - Cleanup

    func removeVolume(for pid: pid_t) {
        states.removeValue(forKey: pid)
    }

    func cleanup(keeping pids: Set<pid_t>) {
        states = states.filter { pids.contains($0.key) }
    }

    // MARK: - Private

    private func ensureState(for pid: pid_t, identifier: String) {
        if states[pid] == nil {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            states[pid] = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
        } else if states[pid]?.persistenceIdentifier != identifier {
            states[pid]?.persistenceIdentifier = identifier
        }
    }

    private static func normalizedUIDOrder(_ preferredOrder: [String], selectedUIDs: Set<String>) -> [String] {
        guard !selectedUIDs.isEmpty else { return [] }

        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(selectedUIDs.count)

        for uid in preferredOrder where selectedUIDs.contains(uid) && !uid.isEmpty {
            if seen.insert(uid).inserted {
                ordered.append(uid)
            }
        }

        let missing = selectedUIDs.filter { !seen.contains($0) }.sorted()
        ordered.append(contentsOf: missing)
        return ordered
    }
}
