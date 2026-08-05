// FineTune/Utilities/URLHandler.swift
import Foundation
import os

/// Protocol for the AudioEngine surface that URLHandler depends on.
/// Extracted for testability (allows mock injection).
@MainActor
protocol URLHandlerEngine {
    var apps: [AudioApp] { get }
    var settingsManager: SettingsManager { get }
    func setVolume(for app: AudioApp, to volume: Float)
    func getVolume(for app: AudioApp) -> Float
    func setMute(for app: AudioApp, to muted: Bool)
    func getMute(for app: AudioApp) -> Bool
    func setDevice(for app: AudioApp, deviceUID: String?)
    func setVolumeForInactive(identifier: String, to volume: Float)
    func setMuteForInactive(identifier: String, to muted: Bool)
    func getMuteForInactive(identifier: String) -> Bool
    func setGroupVolume(id: UUID, to volume: Float)
    func setGroupMute(id: UUID, to muted: Bool)
    func toggleGroupMute(id: UUID)
    func setGroupDevice(id: UUID, deviceUID: String?)
}

/// Handles URL scheme actions for FineTune (finetune://...)
@MainActor
final class URLHandler {
    private let audioEngine: any URLHandlerEngine
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "URLHandler")

    init(audioEngine: any URLHandlerEngine) {
        self.audioEngine = audioEngine
    }

    func handleURL(_ url: URL) {
        logger.info("Received URL: \(url.absoluteString)")

        guard url.scheme == "finetune" else {
            logger.warning("Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = components?.host
        let queryItems = components?.queryItems ?? []

        switch host {
        case "set-volumes":
            handleSetVolumes(queryItems: queryItems)
        case "step-volume":
            handleStepVolume(queryItems: queryItems)
        case "set-mute":
            handleSetMute(queryItems: queryItems)
        case "toggle-mute":
            handleToggleMute(queryItems: queryItems)
        case "set-device":
            handleSetDevice(queryItems: queryItems)
        case "reset":
            handleReset(queryItems: queryItems)
        default:
            logger.warning("Unknown URL action: \(host ?? "nil")")
        }
    }

    // MARK: - Volume Actions

    /// Set volumes for one or more apps and/or groups.
    /// URL format:
    ///   finetune://set-volumes?app=com.a&volume=100&group=Voice&volume=50
    /// Volume is percentage: 0-100 (gain only; boost is separate).
    private func handleSetVolumes(queryItems: [URLQueryItem]) {
        enum Target {
            case app(String)
            case group(String)
        }

        var pairs: [(target: Target, volume: Int)] = []
        var current: Target?

        for item in queryItems {
            switch item.name.lowercased() {
            case "app":
                if let value = item.value { current = .app(value) }
            case "group":
                if let value = item.value { current = .group(value) }
            case "volume":
                guard let target = current else {
                    logger.warning("set-volumes: volume parameter without preceding app/group")
                    continue
                }
                guard let volumeStr = item.value,
                      let volume = Int(volumeStr),
                      (0...100).contains(volume) else {
                    logger.warning("set-volumes: invalid volume '\(item.value ?? "nil")' (valid range: 0-100)")
                    current = nil
                    continue
                }
                pairs.append((target, volume))
                current = nil
            default:
                continue
            }
        }

        if let trailing = current {
            switch trailing {
            case .app(let id):
                logger.warning("set-volumes: trailing app '\(id)' without volume parameter")
            case .group(let id):
                logger.warning("set-volumes: trailing group '\(id)' without volume parameter")
            }
        }

        guard !pairs.isEmpty else {
            logger.error("set-volumes: No valid app/group volume pairs found")
            return
        }

        for (target, volumePercent) in pairs {
            let gain = Float(volumePercent) / 100.0
            switch target {
            case .app(let identifier):
                if let app = findApp(by: identifier) {
                    audioEngine.setVolume(for: app, to: gain)
                    logger.info("Set volume for \(app.name) to \(volumePercent)%")
                } else {
                    audioEngine.setVolumeForInactive(identifier: identifier, to: gain)
                    logger.info("Set volume for inactive app \(identifier) to \(volumePercent)%")
                }
            case .group(let identifier):
                guard let group = findGroup(by: identifier) else {
                    logger.warning("set-volumes: group not found '\(identifier)'")
                    continue
                }
                audioEngine.setGroupVolume(id: group.id, to: gain)
                logger.info("Set volume for group \(group.name) to \(volumePercent)%")
            }
        }
    }

    /// Step volume up or down for an app or group.
    /// URL format: finetune://step-volume?app=com.a&direction=up
    ///             finetune://step-volume?group=Voice&direction=down
    private func handleStepVolume(queryItems: [URLQueryItem]) {
        let appIdentifier = queryItems.first(where: { $0.name.lowercased() == "app" })?.value
        let groupIdentifier = queryItems.first(where: { $0.name.lowercased() == "group" })?.value

        guard appIdentifier != nil || groupIdentifier != nil else {
            logger.error("step-volume: missing app or group parameter")
            return
        }

        guard let direction = queryItems.first(where: { $0.name.lowercased() == "direction" })?.value else {
            logger.error("step-volume: missing direction parameter (use 'up' or 'down')")
            return
        }

        let stepAmount: Double = 0.05
        let applyStep: (Float) -> Float = { currentGain in
            var sliderPosition = VolumeMapping.gainToSlider(currentGain)
            switch direction.lowercased() {
            case "up", "+":
                sliderPosition = min(1.0, sliderPosition + stepAmount)
            case "down", "-":
                sliderPosition = max(0.0, sliderPosition - stepAmount)
            default:
                return currentGain
            }
            return VolumeMapping.sliderToGain(sliderPosition)
        }

        switch direction.lowercased() {
        case "up", "+", "down", "-":
            break
        default:
            logger.error("step-volume: invalid direction '\(direction)'. Use 'up' or 'down'")
            return
        }

        if let groupIdentifier {
            guard let group = findGroup(by: groupIdentifier) else {
                logger.warning("step-volume: group not found '\(groupIdentifier)'")
                return
            }
            let newGain = applyStep(group.volume)
            audioEngine.setGroupVolume(id: group.id, to: newGain)
            let newPercent = Int(round(VolumeMapping.gainToSlider(newGain) * 100))
            logger.info("Stepped volume \(direction) for group \(group.name) to \(newPercent)%")
            return
        }

        if let appIdentifier {
            guard let app = findApp(by: appIdentifier) else {
                logger.warning("step-volume: app not found '\(appIdentifier)'")
                return
            }
            let newGain = applyStep(audioEngine.getVolume(for: app))
            audioEngine.setVolume(for: app, to: newGain)
            let newPercent = Int(round(newGain * 100))
            logger.info("Stepped volume \(direction) for \(app.name) to \(newPercent)%")
        }
    }

    // MARK: - Mute Actions

    /// Set mute state for one or more apps and/or groups.
    /// URL format: finetune://set-mute?app=com.a&muted=true&group=Voice&muted=false
    private func handleSetMute(queryItems: [URLQueryItem]) {
        enum Target {
            case app(String)
            case group(String)
        }

        var pairs: [(target: Target, muted: Bool)] = []
        var current: Target?

        for item in queryItems {
            switch item.name.lowercased() {
            case "app":
                if let value = item.value { current = .app(value) }
            case "group":
                if let value = item.value { current = .group(value) }
            case "muted":
                guard let target = current else {
                    logger.warning("set-mute: muted parameter without preceding app/group")
                    continue
                }
                guard let mutedStr = item.value,
                      let muted = parseBool(mutedStr) else {
                    logger.warning("set-mute: invalid muted value '\(item.value ?? "nil")'")
                    current = nil
                    continue
                }
                pairs.append((target, muted))
                current = nil
            default:
                continue
            }
        }

        if current != nil {
            logger.warning("set-mute: trailing app/group without muted parameter")
        }

        guard !pairs.isEmpty else {
            logger.error("set-mute: No valid app/group muted pairs found")
            return
        }

        for (target, muted) in pairs {
            switch target {
            case .app(let identifier):
                if let app = findApp(by: identifier) {
                    audioEngine.setMute(for: app, to: muted)
                    logger.info("Set mute for \(app.name) to \(muted)")
                } else {
                    audioEngine.setMuteForInactive(identifier: identifier, to: muted)
                    logger.info("Set mute for inactive app \(identifier) to \(muted)")
                }
            case .group(let identifier):
                guard let group = findGroup(by: identifier) else {
                    logger.warning("set-mute: group not found '\(identifier)'")
                    continue
                }
                audioEngine.setGroupMute(id: group.id, to: muted)
                logger.info("Set mute for group \(group.name) to \(muted)")
            }
        }
    }

    /// Toggle mute for apps and/or groups.
    /// URL format: finetune://toggle-mute?app=com.a&group=Voice
    private func handleToggleMute(queryItems: [URLQueryItem]) {
        let appIdentifiers = queryItems
            .filter { $0.name.lowercased() == "app" }
            .compactMap(\.value)
        let groupIdentifiers = queryItems
            .filter { $0.name.lowercased() == "group" }
            .compactMap(\.value)

        guard !appIdentifiers.isEmpty || !groupIdentifiers.isEmpty else {
            logger.error("toggle-mute: No app or group identifiers provided")
            return
        }

        for identifier in appIdentifiers {
            if let app = findApp(by: identifier) {
                let current = audioEngine.getMute(for: app)
                audioEngine.setMute(for: app, to: !current)
                logger.info("Toggled mute for \(app.name) to \(!current)")
            } else {
                let current = audioEngine.getMuteForInactive(identifier: identifier)
                audioEngine.setMuteForInactive(identifier: identifier, to: !current)
                logger.info("Toggled mute for inactive app \(identifier) to \(!current)")
            }
        }

        for identifier in groupIdentifiers {
            guard let group = findGroup(by: identifier) else {
                logger.warning("toggle-mute: group not found '\(identifier)'")
                continue
            }
            audioEngine.toggleGroupMute(id: group.id)
            logger.info("Toggled mute for group \(group.name)")
        }
    }

    // MARK: - Other Actions

    /// Set output device for an app or group.
    /// URL format: finetune://set-device?app=com.a&device=<deviceUID>
    ///             finetune://set-device?group=Voice&device=<deviceUID>
    ///             finetune://set-device?group=Voice&device=default  (follow system default)
    private func handleSetDevice(queryItems: [URLQueryItem]) {
        let appIdentifier = queryItems.first(where: { $0.name.lowercased() == "app" })?.value
        let groupIdentifier = queryItems.first(where: { $0.name.lowercased() == "group" })?.value

        guard appIdentifier != nil || groupIdentifier != nil else {
            logger.error("set-device: missing app or group parameter")
            return
        }

        guard let deviceUID = queryItems.first(where: { $0.name.lowercased() == "device" })?.value else {
            logger.error("set-device: missing device parameter")
            return
        }

        let resolvedUID: String? = {
            switch deviceUID.lowercased() {
            case "default", "system", "follow":
                return nil
            default:
                return deviceUID
            }
        }()

        if let groupIdentifier {
            guard let group = findGroup(by: groupIdentifier) else {
                logger.warning("set-device: group not found '\(groupIdentifier)'")
                return
            }
            audioEngine.setGroupDevice(id: group.id, deviceUID: resolvedUID)
            logger.info("Routed group \(group.name) to \(resolvedUID ?? "system default")")
            return
        }

        if let appIdentifier {
            guard let app = findApp(by: appIdentifier) else {
                logger.warning("set-device: app not found '\(appIdentifier)'")
                return
            }
            audioEngine.setDevice(for: app, deviceUID: resolvedUID)
            logger.info("Routed \(app.name) to \(resolvedUID ?? "system default")")
        }
    }

    /// Reset apps/groups to 100% volume and unmute.
    /// URL format: finetune://reset
    ///             finetune://reset?app=com.a&group=Voice
    private func handleReset(queryItems: [URLQueryItem]) {
        let appIdentifiers = queryItems
            .filter { $0.name.lowercased() == "app" }
            .compactMap(\.value)
        let groupIdentifiers = queryItems
            .filter { $0.name.lowercased() == "group" }
            .compactMap(\.value)

        if appIdentifiers.isEmpty && groupIdentifiers.isEmpty {
            let apps = audioEngine.apps
            let groups = audioEngine.settingsManager.appGroups
            for app in apps {
                audioEngine.setVolume(for: app, to: 1.0)
                audioEngine.setMute(for: app, to: false)
            }
            for group in groups {
                audioEngine.setGroupVolume(id: group.id, to: 1.0)
                audioEngine.setGroupMute(id: group.id, to: false)
            }
            logger.info("Reset all \(apps.count) apps and \(groups.count) groups to 100% (unmuted)")
            return
        }

        for identifier in appIdentifiers {
            if let app = findApp(by: identifier) {
                audioEngine.setVolume(for: app, to: 1.0)
                audioEngine.setMute(for: app, to: false)
                logger.info("Reset \(app.name) to 100% (unmuted)")
            } else {
                audioEngine.setVolumeForInactive(identifier: identifier, to: 1.0)
                audioEngine.setMuteForInactive(identifier: identifier, to: false)
                logger.info("Reset inactive app \(identifier) to 100% (unmuted)")
            }
        }

        for identifier in groupIdentifiers {
            guard let group = findGroup(by: identifier) else {
                logger.warning("reset: group not found '\(identifier)'")
                continue
            }
            audioEngine.setGroupVolume(id: group.id, to: 1.0)
            audioEngine.setGroupMute(id: group.id, to: false)
            logger.info("Reset group \(group.name) to 100% (unmuted)")
        }
    }

    // MARK: - Helpers

    /// Find an app by bundle ID or persistence identifier
    private func findApp(by identifier: String) -> AudioApp? {
        audioEngine.apps.first { $0.persistenceIdentifier == identifier }
    }

    /// Find a group by UUID string or case-insensitive name.
    private func findGroup(by identifier: String) -> AppGroup? {
        let groups = audioEngine.settingsManager.appGroups
        if let uuid = UUID(uuidString: identifier) {
            return groups.first { $0.id == uuid }
        }
        return groups.first {
            $0.name.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    /// Parse boolean from string (supports true/false, 1/0, yes/no)
    private func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}
