// FineTune/Audio/Extensions/AudioObjectID+Readiness.swift
import AudioToolbox
import CoreFoundation

// MARK: - Device Readiness

extension AudioObjectID {
    /// Check if an audio device is currently alive and operational.
    /// Uses kAudioDevicePropertyDeviceIsAlive to verify device state.
    /// - Returns: `true` if device is alive, `false` if dead or query fails.
    func isDeviceAlive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    /// Wait for an audio device to become ready, processing HAL events via CFRunLoop.
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds (default: 1.0)
    ///   - pollInterval: Time between readiness checks in seconds (default: 0.01)
    /// - Returns: `true` if device became ready within timeout, `false` otherwise.
    /// - Warning: This method blocks the calling thread via CFRunLoopRunInMode. Do not call from the main thread without careful consideration.
    /// - Note: Uses CFRunLoopRunInMode to allow Core Audio HAL events to be processed
    ///         during the wait. This is critical for aggregate device initialization.
    func waitUntilReady(timeout: TimeInterval = 1.0, pollInterval: TimeInterval = 0.01) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout

        while CFAbsoluteTimeGetCurrent() < deadline {
            if isDeviceAlive() {
                return true
            }
            // Process HAL events while waiting - critical for aggregate device stabilization
            CFRunLoopRunInMode(.defaultMode, pollInterval, false)
        }

        return false
    }

    /// Check if device has valid output streams configured.
    /// Use after waitUntilReady() for extra verification on aggregate devices.
    /// - Returns: `true` if device has at least one output stream.
    func hasValidOutputStreams() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        return status == noErr && size >= UInt32(MemoryLayout<AudioBufferList>.size)
    }
}
