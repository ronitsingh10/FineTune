// FineTune/Audio/Loopback/LoopbackDeviceManager.swift
//
// Manages the lifecycle of the FineTune Loopback virtual audio device system:
//   - Checks if the HAL plugin driver is installed
//   - Installs the driver (with admin privileges)
//   - Creates/destroys the shared memory ring buffer
//   - Tracks which apps are routing audio to loopback

import Foundation
import os

/// Path where CoreAudio HAL plugins are installed
private let kHALPluginDir = "/Library/Audio/Plug-Ins/HAL"
private let kDriverBundleName = "FineTuneLoopback.driver"
private let kDriverInstallPath = "\(kHALPluginDir)/\(kDriverBundleName)"

@Observable
@MainActor
final class LoopbackDeviceManager {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "LoopbackDeviceManager")

    // MARK: - Observable State

    /// Whether the HAL plugin driver is installed at /Library/Audio/Plug-Ins/HAL/
    private(set) var isDriverInstalled: Bool = false

    /// Whether the loopback system is currently active (ring buffer exists and is accepting audio)
    private(set) var isActive: Bool = false

    /// PIDs of apps currently routing audio to loopback
    private(set) var activeApps: Set<pid_t> = []

    // MARK: - Internal State

    /// The shared memory ring buffer (created when loopback is enabled)
    private var ringBuffer: LoopbackRingBuffer?

    /// Current configuration
    private(set) var currentSampleRate: Float64 = 48000.0
    private(set) var currentChannels: UInt32 = 2

    // MARK: - Init

    init() {
        isDriverInstalled = checkDriverInstalled()
        if isDriverInstalled {
            logger.info("FineTune Loopback driver found at \(kDriverInstallPath)")
        } else {
            logger.info("FineTune Loopback driver not installed")
        }
    }

    // MARK: - Driver Installation

    /// Checks if the HAL plugin is installed at the expected path.
    func checkDriverInstalled() -> Bool {
        FileManager.default.fileExists(atPath: kDriverInstallPath)
    }

    /// Installs the HAL plugin driver from the app bundle to /Library/Audio/Plug-Ins/HAL/.
    /// Requires admin privileges — uses osascript to prompt for password.
    ///
    /// After installation, restarts coreaudiod so the HAL picks up the new plugin.
    func installDriver() async throws {
        // Find the driver bundle in our app resources
        guard let driverSourceURL = Bundle.main.url(forResource: "FineTuneLoopback", withExtension: "driver") else {
            logger.error("FineTuneLoopback.driver not found in app bundle")
            throw LoopbackError.driverNotInstalled
        }

        let sourcePath = driverSourceURL.path
        let installPath = kDriverInstallPath

        logger.info("Installing driver from \(sourcePath) to \(installPath)")

        // Build the shell command for privileged installation
        // 1. Remove old driver if present
        // 2. Copy new driver
        // 3. Set correct ownership
        // 4. Restart coreaudiod to load the new plugin
        let shellScript = """
            rm -rf '\(installPath)' && \
            cp -R '\(sourcePath)' '\(installPath)' && \
            chown -R root:wheel '\(installPath)' && \
            launchctl kickstart -kp system/com.apple.audio.coreaudiod
            """

        // Use osascript to get admin privileges
        let script = "do shell script \"\(shellScript.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.error("Driver installation failed: \(errorString)")
            throw LoopbackInstallError.installFailed(errorString)
        }

        // Wait a moment for coreaudiod to restart and load the plugin
        try await Task.sleep(for: .seconds(2))

        self.isDriverInstalled = checkDriverInstalled()
        if self.isDriverInstalled {
            logger.info("Driver installed successfully")
        } else {
            logger.error("Driver installation verification failed — file not found after install")
            throw LoopbackInstallError.verificationFailed
        }
    }

    /// Uninstalls the HAL plugin driver.
    func uninstallDriver() async throws {
        let installPath = kDriverInstallPath

        let shellScript = """
            rm -rf '\(installPath)' && \
            launchctl kickstart -kp system/com.apple.audio.coreaudiod
            """

        let script = "do shell script \"\(shellScript.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        try process.run()
        process.waitUntilExit()

        try await Task.sleep(for: .seconds(2))

        self.isDriverInstalled = checkDriverInstalled()
        logger.info("Driver uninstalled: \(!self.isDriverInstalled)")
    }

    // MARK: - Loopback Lifecycle

    /// Enables the loopback system — creates the shared memory ring buffer.
    /// Call this before routing any apps to loopback.
    ///
    /// - Parameters:
    ///   - sampleRate: Audio sample rate (default: 48000.0)
    ///   - channels: Number of channels (default: 2 for stereo)
    /// - Returns: The ring buffer for assigning to ProcessTapControllers
    @discardableResult
    func enableLoopback(sampleRate: Float64 = 48000.0, channels: UInt32 = 2) throws -> LoopbackRingBuffer {
        guard isDriverInstalled else {
            throw LoopbackError.driverNotInstalled
        }

        // Reuse existing buffer if configuration matches
        if let existing = ringBuffer,
           existing.sampleRate == sampleRate,
           existing.channels == channels {
            return existing
        }

        // Tear down existing buffer if configuration changed
        if ringBuffer != nil {
            disableLoopback()
        }

        let buffer = try LoopbackRingBuffer(sampleRate: sampleRate, channels: channels)
        buffer.activate()

        ringBuffer = buffer
        currentSampleRate = sampleRate
        currentChannels = channels
        isActive = true

        logger.info("Loopback enabled: \(sampleRate)Hz, \(channels)ch")
        return buffer
    }

    /// Disables the loopback system — destroys the shared memory ring buffer.
    /// All apps routing to loopback will stop.
    func disableLoopback() {
        ringBuffer?.deactivate()
        ringBuffer = nil
        activeApps.removeAll()
        isActive = false
        logger.info("Loopback disabled")
    }

    /// Gets the current ring buffer (for assigning to taps).
    /// Returns nil if loopback is not enabled.
    func getRingBuffer() -> LoopbackRingBuffer? {
        ringBuffer
    }

    // MARK: - App Tracking

    /// Registers an app as routing to loopback.
    func addApp(_ pid: pid_t) {
        activeApps.insert(pid)
        logger.debug("App \(pid) added to loopback routing")
    }

    /// Unregisters an app from loopback routing.
    func removeApp(_ pid: pid_t) {
        activeApps.remove(pid)
        logger.debug("App \(pid) removed from loopback routing")

        // If no apps are using loopback, we keep the buffer alive
        // but the HAL plugin will receive silence (no audio being written).
        // The user can explicitly disable loopback in settings to tear down.
    }

    /// Checks if an app is currently routing to loopback.
    func isAppRouted(_ pid: pid_t) -> Bool {
        activeApps.contains(pid)
    }
}

// MARK: - Installation Errors

enum LoopbackInstallError: Error, LocalizedError {
    case installFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .installFailed(let detail):
            return "Failed to install loopback driver: \(detail)"
        case .verificationFailed:
            return "Driver installation could not be verified"
        }
    }
}
