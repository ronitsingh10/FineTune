/// Abstraction over process tap controllers for testability.
///
/// **Threading:** The protocol surface is `@MainActor` — AudioEngine and tests
/// interact with controllers from main. The concrete class straddles main and the
/// CoreAudio HAL I/O thread, but the audio callback never goes through this
/// protocol; it reads `nonisolated(unsafe)` atomic fields directly on the concrete
/// type via a `void *` userdata pointer.
@MainActor
protocol ProcessTapControlling: AnyObject, Sendable {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    /// A source mute independent of any output device or rendering aggregate.
    var persistentOutputGuardEnabled: Bool { get }
    /// Policy silence, separate from the user's mute preference.
    var outputBlocked: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }

    func activate(initial: TapInitialState) throws
    func setPersistentOutputGuardEnabled(_ enabled: Bool) throws
    /// Replace source membership without a gap in the existing source mute.
    func updateGuardedApp(_ app: AudioApp) throws
    /// Always rebuilds, even for the same UID after a hardware reconnection.
    /// The caller must recheck availability before clearing `outputBlocked`.
    func restoreGuardedOutput(to deviceUID: String, preferredTapSourceDeviceUID: String?) async throws
    func invalidate()
    func invalidateAsync() async
    func updateEQSettings(_ settings: EQSettings)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    func updateLoudnessCompensation(volume: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    var tapSourceDeviceUID: String? { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws
    func recreateForOutputRateChange() async throws
}

extension ProcessTapControlling {
    /// Convenience activation with default state. Production callers must pass an
    /// `initial:` populated from persisted settings — defaults leave the first audio
    /// callbacks running with no EQ/AutoEQ/Loudness and unity volume ramp.
    func activate() throws {
        try activate(initial: TapInitialState())
    }

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

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        // Default no-op for mocks that don't override
    }

    func recreateForOutputRateChange() async throws {
        // Default no-op for mocks that don't override
    }
}
