// FineTune/Audio/Loopback/LoopbackDeviceManager.swift
//
// Manages the lifecycle of the FineTune Loopback virtual audio device system:
//   - Checks if the HAL plugin driver is installed
//   - Installs the driver (with admin privileges)
//   - Creates/destroys the shared memory ring buffer
//   - Tracks which apps are routing audio to loopback

import Foundation
import AudioToolbox
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
        // TODO: M12 — Replace waitUntilExit() with async continuation using process.terminationHandler
        // to avoid blocking the main thread during driver installation.
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
        // TODO: M12 — Replace waitUntilExit() with async continuation using process.terminationHandler
        // to avoid blocking the main thread during driver uninstallation.
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            logger.error("Driver uninstall failed with exit code \(process.terminationStatus)")
            self.isDriverInstalled = checkDriverInstalled()
            return
        }

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

    // MARK: - Lossless Recording Mode (Virtual Audio Cable)

    /// The UID of the FineTune Loopback virtual audio device.
    static let loopbackDeviceUID = "com.finetuneapp.loopback"

    /// Enables lossless recording mode: saves the current system output device,
    /// then switches system output to FineTune Loopback so apps output through
    /// the virtual cable.
    ///
    /// Returns the UID of the previous output device (for later restoration).
    @discardableResult
    func enableLosslessRecording() -> String? {
        guard isDriverInstalled else {
            logger.error("Cannot enable lossless recording: driver not installed")
            return nil
        }

        // Save current default output device UID
        let previousUID = Self.currentDefaultOutputDeviceUID()
        logger.info("Lossless recording: saving previous output device: \(previousUID ?? "nil")")

        // Find the FineTune Loopback device and set it as default output
        guard let loopbackID = Self.findDeviceByUID(Self.loopbackDeviceUID) else {
            logger.error("FineTune Loopback device not found in audio system")
            return nil
        }

        let err = Self.setDefaultOutputDevice(loopbackID)
        if err == noErr {
            isLosslessRecordingActive = true
            logger.info("Lossless recording enabled: system output → FineTune Loopback")
        } else {
            logger.error("Failed to set FineTune Loopback as default output: \(err)")
        }

        return previousUID
    }

    /// Disables lossless recording mode: restores the specified output device
    /// as the system default.
    func disableLosslessRecording(restoreDeviceUID: String?) {
        if let uid = restoreDeviceUID, let deviceID = Self.findDeviceByUID(uid) {
            let err = Self.setDefaultOutputDevice(deviceID)
            if err == noErr {
                logger.info("Lossless recording disabled: restored output → \(uid)")
            } else {
                logger.error("Failed to restore output device \(uid): \(err)")
            }
        } else {
            // Fallback: query the current system default output device.
            // If it's still our loopback device, enumerate all outputs
            // and pick the first non-loopback device.
            var fallbackID = AudioObjectID(kAudioObjectUnknown)
            var fbSize = UInt32(MemoryLayout<AudioObjectID>.size)
            var fbAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let fbErr = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &fbAddr, 0, nil, &fbSize, &fallbackID)

            if fbErr == noErr && fallbackID != kAudioObjectUnknown {
                // Check if the current default is our loopback device
                let currentUID = Self.deviceUID(for: fallbackID)
                if currentUID == Self.loopbackDeviceUID {
                    // Find first non-loopback output device
                    if let nonLoopback = Self.firstNonLoopbackOutputDevice() {
                        Self.setDefaultOutputDevice(nonLoopback)
                        logger.info("Lossless recording disabled: restored to first non-loopback device")
                    } else {
                        logger.warning("Lossless recording disabled: no non-loopback device found")
                    }
                } else {
                    Self.setDefaultOutputDevice(fallbackID)
                    logger.info("Lossless recording disabled: restored to current default")
                }
            } else {
                logger.warning("Lossless recording disabled: could not query default output device")
            }
        }

        isLosslessRecordingActive = false
    }

    /// Whether lossless recording mode is currently active (system output is FineTune Loopback).
    private(set) var isLosslessRecordingActive: Bool = false

    // MARK: - CoreAudio Helpers

    /// Returns the UID of the current default output device.
    private static func currentDefaultOutputDeviceUID() -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFTypeRef? = nil
        var uidSize = UInt32(MemoryLayout<CFTypeRef>.size)
        let uidErr = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid)
        guard uidErr == noErr else { return nil }
        guard let uidString = uid as? String else { return nil }
        return uidString
    }

    /// Finds an AudioDeviceID by its UID string.
    private static func findDeviceByUID(_ uid: String) -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &devices)

        for dev in devices {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var devUID: CFTypeRef? = nil
            var uidSize = UInt32(MemoryLayout<CFTypeRef>.size)
            AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &devUID)
            if let devUIDString = devUID as? String, devUIDString == uid {
                return dev
            }
        }
        return nil
    }

    /// Sets the default system output device.
    @discardableResult
    private static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &devID
        )
    }

    /// Returns the UID string for a given AudioDeviceID, or nil.
    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFTypeRef? = nil
        var uidSize = UInt32(MemoryLayout<CFTypeRef>.size)
        let err = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid)
        guard err == noErr else { return nil }
        return uid as? String
    }

    /// Returns the first non-loopback output device ID by enumerating all devices.
    private static func firstNonLoopbackOutputDevice() -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &devices)

        for dev in devices {
            guard let uid = deviceUID(for: dev), uid != loopbackDeviceUID else { continue }
            // Check this device has output streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize)
            if streamSize > 0 {
                return dev
            }
        }
        return nil
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
