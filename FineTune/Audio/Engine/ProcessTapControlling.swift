/// Abstraction over process tap controllers for testability.
///
/// **Threading:** Intentionally NOT `@MainActor`. Concrete implementations straddle
/// the main thread (property access from AudioEngine) and the CoreAudio HAL I/O thread
/// (audio processing callbacks). Thread safety for mutable properties (`volume`, `isMuted`,
/// `currentDeviceVolume`, `isDeviceMuted`) is achieved via `nonisolated(unsafe)` atomic
/// field access on the concrete type, not actor isolation.
protocol ProcessTapControlling: AnyObject {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }

    func activate() throws
    func invalidate()
    func invalidateAsync() async
    func updateEQSettings(_ settings: EQSettings)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    func updateLoudnessCompensation(volume: Float, enabled: Bool, intensity: Float)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func setLoudnessEqualizationIntensity(_ intensity: Float)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    var tapSourceDeviceUID: String? { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws

}

extension ProcessTapControlling {
    /// Convenience: defaults sourceDeviceDead to false.
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?) async throws {
        try await switchDevice(to: newDeviceUID, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?) async throws {
        try await updateDevices(to: newDeviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    func invalidateAsync() async {
        invalidate()
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        updateLoudnessCompensation(volume: volume, enabled: enabled, intensity: 1.0)
    }

    func setLoudnessEqualizationIntensity(_ intensity: Float) {
        // Default no-op for mocks
    }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        // Default no-op for mocks that don't override
    }

}
