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
    var boost: BoostLevel = .x1
    var monoDownmix: Bool = false
    var deviceSelectionMode: DeviceSelectionMode = .single
    var selectedDeviceUIDs: Set<String> = []  // Used in multi mode
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

    // MARK: - Boost

    func getBoost(for pid: pid_t) -> BoostLevel {
        states[pid]?.boost ?? .x1
    }

    func setBoost(for pid: pid_t, to boost: BoostLevel, identifier: String? = nil) {
        if var state = states[pid] {
            state.boost = boost
            if let identifier = identifier {
                state.persistenceIdentifier = identifier
            }
            states[pid] = state
            settingsManager?.setBoost(for: state.persistenceIdentifier, to: boost)
        } else if let identifier = identifier {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            var newState = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
            newState.boost = boost
            states[pid] = newState
            settingsManager?.setBoost(for: identifier, to: boost)
        }
    }

    func loadSavedBoost(for pid: pid_t, identifier: String) -> BoostLevel? {
        ensureState(for: pid, identifier: identifier)
        if let saved = settingsManager?.getBoost(for: identifier) {
            states[pid]?.boost = saved
            return saved
        }
        return nil
    }

    // MARK: - Mono Downmix

    func getMonoDownmix(for pid: pid_t) -> Bool {
        states[pid]?.monoDownmix ?? false
    }

    func setMonoDownmix(for pid: pid_t, to enabled: Bool, identifier: String? = nil) {
        if var state = states[pid] {
            state.monoDownmix = enabled
            if let identifier = identifier {
                state.persistenceIdentifier = identifier
            }
            states[pid] = state
            settingsManager?.setMonoDownmix(for: state.persistenceIdentifier, to: enabled)
        } else if let identifier = identifier {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            var newState = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
            newState.monoDownmix = enabled
            states[pid] = newState
            settingsManager?.setMonoDownmix(for: identifier, to: enabled)
        }
    }

    func loadSavedMonoDownmix(for pid: pid_t, identifier: String) -> Bool? {
        ensureState(for: pid, identifier: identifier)
        let saved = settingsManager?.getMonoDownmix(for: identifier)
        states[pid]?.monoDownmix = saved ?? false
        return saved
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

    func setSelectedDeviceUIDs(for pid: pid_t, to uids: Set<String>, identifier: String? = nil) {
        if var state = states[pid] {
            state.selectedDeviceUIDs = uids
            if let identifier = identifier {
                state.persistenceIdentifier = identifier
            }
            states[pid] = state
            settingsManager?.setSelectedDeviceUIDs(for: state.persistenceIdentifier, to: uids)
        } else if let identifier = identifier {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            var newState = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
            newState.selectedDeviceUIDs = uids
            states[pid] = newState
            settingsManager?.setSelectedDeviceUIDs(for: identifier, to: uids)
        }
    }

    func loadSavedSelectedDeviceUIDs(for pid: pid_t, identifier: String) -> Set<String>? {
        ensureState(for: pid, identifier: identifier)
        if let saved = settingsManager?.getSelectedDeviceUIDs(for: identifier) {
            states[pid]?.selectedDeviceUIDs = saved
            return saved
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

    func resetAll() {
        states.removeAll()
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
}
