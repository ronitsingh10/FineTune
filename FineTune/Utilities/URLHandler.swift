// FineTune/Utilities/URLHandler.swift
import Foundation
import os

/// Handles URL scheme actions for FineTune (finetune://...)
@MainActor
final class URLHandler {
    private let audioEngine: AudioEngine
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "URLHandler")
    
    init(audioEngine: AudioEngine) {
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
        case "volume":
            handleVolumeAction(queryItems: queryItems)
        case "mute":
            handleMuteAction(queryItems: queryItems)
        case "device":
            handleDeviceAction(queryItems: queryItems)
        default:
            logger.warning("Unknown URL action: \(host ?? "nil")")
        }
    }
    
    private func handleVolumeAction(queryItems: [URLQueryItem]) {
        guard let appIdentifier = queryItems.first(where: { $0.name == "app" })?.value else {
            logger.error("Invalid volume URL parameters: missing app")
            return
        }
        
        Task { @MainActor in
            guard let app = findApp(by: appIdentifier) else {
                logger.warning("App not found: \(appIdentifier)")
                return
            }
            
            if let stepDirection = queryItems.first(where: { $0.name == "step" })?.value {
                let currentVolume = audioEngine.getVolume(for: app)
                let stepAmount: Float = 0.1 // 10% adjustment per step
                
                let newVolume: Float
                switch stepDirection.lowercased() {
                case "up", "+":
                    newVolume = currentVolume + stepAmount
                case "down", "-":
                    newVolume = currentVolume - stepAmount
                default:
                    logger.error("Invalid step direction: \(stepDirection). Use 'up' or 'down'")
                    return
                }
                
                let clampedLevel = max(0.0, min(2.0, newVolume))
                audioEngine.setVolume(for: app, to: clampedLevel)
                logger.info("Adjusted volume for \(app.name) (\(appIdentifier)) \(stepDirection) from \(currentVolume) to \(clampedLevel)")
            }
            else if let levelString = queryItems.first(where: { $0.name == "level" })?.value,
                    let level = Float(levelString) {
                let clampedLevel = max(0.0, min(2.0, level))
                audioEngine.setVolume(for: app, to: clampedLevel)
                logger.info("Set volume for \(app.name) (\(appIdentifier)) to \(clampedLevel)")
            } else {
                logger.error("Invalid volume URL parameters: missing 'level' or 'step' parameter")
            }
        }
    }
    
    private func handleMuteAction(queryItems: [URLQueryItem]) {
        guard let appIdentifier = queryItems.first(where: { $0.name == "app" })?.value,
              let mutedString = queryItems.first(where: { $0.name == "muted" })?.value,
              let muted = Bool(mutedString) else {
            logger.error("Invalid mute URL parameters")
            return
        }
        
        Task { @MainActor in
            guard let app = findApp(by: appIdentifier) else {
                logger.warning("App not found: \(appIdentifier)")
                return
            }
            audioEngine.setMute(for: app, to: muted)
            logger.info("Set mute for \(app.name) (\(appIdentifier)) to \(muted)")
        }
    }
    
    private func handleDeviceAction(queryItems: [URLQueryItem]) {
        guard let appIdentifier = queryItems.first(where: { $0.name == "app" })?.value,
              let deviceUID = queryItems.first(where: { $0.name == "device" })?.value else {
            logger.error("Invalid device URL parameters")
            return
        }
        
        Task { @MainActor in
            guard let app = findApp(by: appIdentifier) else {
                logger.warning("App not found: \(appIdentifier)")
                return
            }
            audioEngine.setDevice(for: app, deviceUID: deviceUID)
            logger.info("Routed \(app.name) (\(appIdentifier)) to device \(deviceUID)")
        }
    }
    
    /// Find an app by bundle ID or persistence identifier
    private func findApp(by identifier: String) -> AudioApp? {
        return audioEngine.apps.first { app in
            app.bundleID == identifier || app.persistenceIdentifier == identifier
        }
    }
}
