// FineTune/Utilities/URLHandler.swift
import Foundation
import AudioToolbox
import os

/// Protocol for the AudioEngine surface that URLHandler depends on.
/// Extracted for testability (allows mock injection).
@MainActor
protocol URLHandlerEngine {
    var apps: [AudioApp] { get }
    var outputDevices: [AudioDevice] { get }
    var bluetoothDeviceMonitor: BluetoothDeviceMonitor { get }
    var settingsManager: SettingsManager { get }
    @discardableResult func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool
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
        case "connect-device":
            handleConnectDevice(queryItems: queryItems)
        case "set-default-output":
            handleSetDefaultOutput(queryItems: queryItems)
        case "reset":
            handleReset(queryItems: queryItems)
        default:
            logger.warning("Unknown URL action: \(host ?? "nil")")
        }
    }
    
    // MARK: - Volume Actions

    /// Set volumes for one or more apps
    /// URL format: finetune://set-volumes?app=com.a&volume=100&app=com.b&volume=50
    /// Volume is percentage: 0-100 (gain only, boost is per-app and set separately)
    private func handleSetVolumes(queryItems: [URLQueryItem]) {
        var pairs: [(identifier: String, volume: Int)] = []
        var currentApp: String?

        // Parse app/volume pairs in order
        for item in queryItems {
            switch item.name.lowercased() {
            case "app":
                currentApp = item.value
            case "volume":
                guard let app = currentApp else {
                    logger.warning("set-volumes: volume parameter without preceding app")
                    continue
                }
                guard let volumeStr = item.value,
                      let volume = Int(volumeStr),
                      (0...100).contains(volume) else {
                    logger.warning("set-volumes: invalid volume '\(item.value ?? "nil")' for app \(app) (valid range: 0-100)")
                    currentApp = nil
                    continue
                }
                pairs.append((app, volume))
                currentApp = nil
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

        for (identifier, volumePercent) in pairs {
            // Linear conversion: volume=100 → gain 1.0
            let gain = Float(volumePercent) / 100.0

            if let app = findApp(by: identifier) {
                audioEngine.setVolume(for: app, to: gain)
                logger.info("Set volume for \(app.name) to \(volumePercent)%")
            } else {
                // App not active - persist for when it launches
                audioEngine.setVolumeForInactive(identifier: identifier, to: gain)
                logger.info("Set volume for inactive app \(identifier) to \(volumePercent)%")
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

    private func handleConnectDevice(queryItems: [URLQueryItem]) {
        guard let name = normalizedQueryValue(queryItems.first(where: { $0.name == "name" })?.value) else {
            logger.error("connect-device: missing name parameter")
            return
        }

        let btMonitor = audioEngine.bluetoothDeviceMonitor

        guard let device = btMonitor.pairedDevices.first(where: {
            $0.name.localizedCaseInsensitiveContains(name)
        }) else {
            logger.warning("connect-device: no paired device found matching '\(name)'")
            return
        }

        btMonitor.connect(device: device)
        logger.info("Connecting to \(device.name)")
    }

    private func handleSetDefaultOutput(queryItems: [URLQueryItem]) {
        let deviceUID = normalizedQueryValue(queryItems.first(where: { $0.name == "device" })?.value)
        let deviceName = normalizedQueryValue(queryItems.first(where: { $0.name == "name" })?.value)

        guard deviceUID != nil || deviceName != nil else {
            logger.error("set-default-output: missing device or name parameter")
            return
        }

        let matchedDevice: AudioDevice?
        if let uid = deviceUID {
            matchedDevice = audioEngine.outputDevices.first(where: { $0.uid == uid })
        } else if let name = deviceName {
            matchedDevice = audioEngine.outputDevices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            })
        } else {
            matchedDevice = nil
        }

        guard let device = matchedDevice else {
            logger.warning("set-default-output: no output device found matching '\(deviceUID ?? deviceName ?? "nil")'")
            return
        }

        if audioEngine.setDefaultOutputDevice(device.id) {
            logger.info("Set default output device to \(device.name)")
        } else {
            logger.error("set-default-output: failed to set default output to \(device.name)")
        }
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

    private func normalizedQueryValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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
