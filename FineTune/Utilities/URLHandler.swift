// FineTune/Utilities/URLHandler.swift
import Foundation
import os

/// Protocol for the AudioEngine surface that URLHandler depends on.
/// Extracted for testability (allows mock injection).
@MainActor
protocol URLHandlerEngine {
    var apps: [AudioApp] { get }
    var audioDevices: [AudioDevice] { get }
    var settingsManager: SettingsManager { get }
    func setVolume(for app: AudioApp, to volume: Float)
    func getVolume(for app: AudioApp) -> Float
    func setMute(for app: AudioApp, to muted: Bool)
    func getMute(for app: AudioApp) -> Bool
    func setDevice(for app: AudioApp, deviceUID: String?)
    func setVolumeForInactive(identifier: String, to volume: Float)
    func setMuteForInactive(identifier: String, to muted: Bool)
    func getMuteForInactive(identifier: String) -> Bool
}

/// Handles URL scheme actions for FineTune (finetune://...)
@MainActor
final class URLHandler {
    private enum VolumeTarget {
        case app(String)
        case device(String)
    }
    
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
        // Volume actions
        case "set-volumes":
            handleSetVolumes(queryItems: queryItems)
        case "step-volume":
            handleStepVolume(queryItems: queryItems)
        // Mute actions
        case "set-mute":
            handleSetMute(queryItems: queryItems)
        case "toggle-mute":
            handleToggleMute(queryItems: queryItems)
        // Other actions
        case "set-device":
            handleSetDevice(queryItems: queryItems)
        case "reset":
            handleReset(queryItems: queryItems)
        default:
            logger.warning("Unknown URL action: \(host ?? "nil")")
        }
    }
    
    // MARK: - Volume Actions

    /// Set volumes for one or more apps or audio device
    /// URL format: app=identifier&volume=value OR device=name&volume=value
    /// You may set multiple app or device at once.
    ///
    /// Examples:
    ///
    ///    finetune://set-volumes?app=com.a&volume=100
    ///    finetune://set-volumes?app=com.a&volume=100&app=com.b&volume=50
    ///
    ///    finetune://set-volumes?device=MacBook Pro Speakers&volume=75
    ///    finetune://set-volumes?device=MacBook Pro Speakers&volume=75&device=AirPods ✌️✌️&volume=25
    ///
    ///    finetune://set-volumes?device=MacBook Pro Speakers&volume=75&app=com.a&volume=100
    ///
    ///
    /// Volume is percentage: 0-100 (gain only, boost is per-app and set separately)
    private func handleSetVolumes(queryItems: [URLQueryItem]) {
        var pairs: [(target: VolumeTarget, volume: Int)] = []
        var currentApp: String?
        var currentDevice: String?

        

        // Parse app/volume pairs in order
        for item in queryItems {
            switch item.name.lowercased() {
            case "app":
                currentApp = item.value
            case "device":
                currentDevice = item.value
            case "volume":
                let app: String? = currentApp
                let device: String? = currentDevice

                guard app != nil || device != nil else {
                    logger.warning("set-volumes: volume parameter without preceding app or device")
                    continue
                }

                guard let volumeStr: String = item.value,
                      let volume: Int = Int(volumeStr),
                      (0...100).contains(volume) else {
                    let appOrDevice: String
                    if let app = app {
                        appOrDevice = "app \(app)"
                    } else {
                        appOrDevice = "device \(device ?? "")"
                    }

                    logger.warning("set-volumes: invalid volume '\(item.value ?? "nil")' for \(appOrDevice) (valid range: 0-100)")
                    currentApp = nil
                    currentDevice = nil
                    continue
                }

                if let app = app {
                    pairs.append((target: .app(app), volume: volume))
                    currentApp = nil
                    currentDevice = nil
                } else if let device = device {
                    pairs.append((target: .device(device), volume: volume))
                    currentApp = nil
                    currentDevice = nil
                }
            default:
                continue
            }
        }

        // Warn about trailing app without volume
        if let trailing = currentApp {
            logger.warning("set-volumes: trailing app '\(trailing)' without volume parameter")
        }

        guard !pairs.isEmpty else {
            logger.error("set-volumes: No valid app/volume pairs found")
            return
        }

        for (target, volumePercent) in pairs {
            let gain: Float = Float(volumePercent) / 100.0

            switch target {
            case .app(let identifier):
                if let app = findApp(by: identifier) {
                    audioEngine.setVolume(for: app, to: gain)
                    logger.info("Set volume for \(app.name) to \(volumePercent)%")
                } else {
                    audioEngine.setVolumeForInactive(identifier: identifier, to: gain)
                    logger.info("Set volume for inactive app \(identifier) to \(volumePercent)%")
                }

            case .device(let identifier):
                if let foundDevice = findDevice(by: identifier) {
                    // TODO: Implement device volume control when available in the engine.
                    _ = foundDevice.id.setOutputVolumeScalar(gain)
                    logger.info("Set volume for device \(foundDevice.id) to \(volumePercent)%")
                } else {
                    logger.warning("Device not found: \(identifier)")
                }
            }
        }
    }

    /// Step volume up or down for an app
    /// URL format: finetune://step-volume?app=com.a&direction=up (or down)
    /// Steps by 5% slider position
    private func handleStepVolume(queryItems: [URLQueryItem]) {
        guard let appIdentifier = queryItems.first(where: { $0.name == "app" })?.value else {
            logger.error("step-volume: missing app parameter")
            return
        }

        guard let direction = queryItems.first(where: { $0.name == "direction" })?.value else {
            logger.error("step-volume: missing direction parameter (use 'up' or 'down')")
            return
        }

        guard let app = findApp(by: appIdentifier) else {
            logger.warning("step-volume: app not found '\(appIdentifier)'")
            return
        }

        let currentGain = audioEngine.getVolume(for: app)
        let stepAmount: Double = 0.05 // 5% slider position
        var sliderPosition = VolumeMapping.gainToSlider(currentGain)

        switch direction.lowercased() {
        case "up", "+":
            sliderPosition = min(1.0, sliderPosition + stepAmount)
        case "down", "-":
            sliderPosition = max(0.0, sliderPosition - stepAmount)
        default:
            logger.error("step-volume: invalid direction '\(direction)'. Use 'up' or 'down'")
            return
        }

        let newGain = VolumeMapping.sliderToGain(sliderPosition)
        audioEngine.setVolume(for: app, to: newGain)
        let newPercent = Int(round(newGain * 100))
        logger.info("Stepped volume \(direction) for \(app.name) to \(newPercent)%")
    }

    // MARK: - Mute Actions

    /// Set mute state for one or more apps
    /// URL format: finetune://set-mute?app=com.a&muted=true&app=com.b&muted=false
    private func handleSetMute(queryItems: [URLQueryItem]) {
        var pairs: [(identifier: String, muted: Bool)] = []
        var currentApp: String?

        for item in queryItems {
            switch item.name.lowercased() {
            case "app":
                currentApp = item.value
            case "muted":
                guard let app = currentApp else {
                    logger.warning("set-mute: muted parameter without preceding app")
                    continue
                }
                guard let mutedStr = item.value,
                      let muted = parseBool(mutedStr) else {
                    logger.warning("set-mute: invalid muted value '\(item.value ?? "nil")' for app \(app)")
                    currentApp = nil
                    continue
                }
                pairs.append((app, muted))
                currentApp = nil
            default:
                continue
            }
        }

        // Warn about trailing app without muted value
        if let trailing = currentApp {
            logger.warning("set-mute: trailing app '\(trailing)' without muted parameter")
        }

        guard !pairs.isEmpty else {
            logger.error("set-mute: No valid app/muted pairs found")
            return
        }

        for (identifier, muted) in pairs {
            if let app = findApp(by: identifier) {
                audioEngine.setMute(for: app, to: muted)
                logger.info("Set mute for \(app.name) to \(muted)")
            } else {
                audioEngine.setMuteForInactive(identifier: identifier, to: muted)
                logger.info("Set mute for inactive app \(identifier) to \(muted)")
            }
        }
    }

    /// Toggle mute state for apps
    /// URL format: finetune://toggle-mute?app=com.a&app=com.b
    private func handleToggleMute(queryItems: [URLQueryItem]) {
        let identifiers = queryItems
            .filter { $0.name.lowercased() == "app" }
            .compactMap { $0.value }

        guard !identifiers.isEmpty else {
            logger.error("toggle-mute: No app identifiers provided")
            return
        }

        for identifier in identifiers {
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
    }

    // MARK: - Other Actions

    /// Set output device for an app
    /// URL format: finetune://set-device?app=com.a&device=<deviceUID>
    private func handleSetDevice(queryItems: [URLQueryItem]) {
        guard let appIdentifier = queryItems.first(where: { $0.name == "app" })?.value else {
            logger.error("set-device: missing app parameter")
            return
        }

        guard let deviceUID = queryItems.first(where: { $0.name == "device" })?.value else {
            logger.error("set-device: missing device parameter")
            return
        }

        guard let app = findApp(by: appIdentifier) else {
            logger.warning("set-device: app not found '\(appIdentifier)'")
            return
        }

        audioEngine.setDevice(for: app, deviceUID: deviceUID)
        logger.info("Routed \(app.name) to device \(deviceUID)")
    }

    /// Reset apps to 100% volume and unmute
    /// URL format: finetune://reset?app=com.a&app=com.b or finetune://reset (all apps)
    private func handleReset(queryItems: [URLQueryItem]) {
        let identifiers = queryItems
            .filter { $0.name.lowercased() == "app" }
            .compactMap { $0.value }

        if identifiers.isEmpty {
            // Reset all active apps to 100% and unmute
            let apps = audioEngine.apps
            for app in apps {
                audioEngine.setVolume(for: app, to: 1.0)
                audioEngine.setMute(for: app, to: false)
            }
            logger.info("Reset all \(apps.count) apps to 100% (unmuted)")
        } else {
            for identifier in identifiers {
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
        }
    }

    // MARK: - Helpers

    /// Find an app by bundle ID or persistence identifier
    private func findApp(by identifier: String) -> AudioApp? {
        audioEngine.apps.first { $0.persistenceIdentifier == identifier }
    }
    
    private func findDevice(by name: String) -> AudioDevice? {
        let audioDevice:AudioDevice? = audioEngine.audioDevices.first { $0.name == name }
        
        if audioDevice == nil {
            logger.info("Searching for device with name: '\(name)'")

            logger.info("all devices names: \(self.audioEngine.audioDevices.map { $0.name })")
        }
        
        return audioDevice
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

