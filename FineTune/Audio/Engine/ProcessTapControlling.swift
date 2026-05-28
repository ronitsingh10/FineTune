import AudioToolbox

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
    func updateLoudnessCompensation(volume: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    var tapSourceDeviceUID: String? { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws

    /// Assigns a loopback ring buffer for cross-process audio routing.
    /// When set, the audio callback forks processed samples to shared memory
    /// so the FineTuneLoopback HAL plugin can read them as an input device.
    /// Pass nil to disconnect from loopback.
    func setLoopbackBuffer(_ buffer: LoopbackRingBuffer?)

    /// Enables unmuted capture mode. When true, the process tap uses `.unmuted`
    /// behavior so the app's own audio output is NOT silenced. The IO callback
    /// captures raw audio to the loopback ring buffer and writes silence to the
    /// aggregate output (preventing double audio). Requires tap recreation.
    var isUnmutedCapture: Bool { get }
    var ioStats: ProcessTapController.IOStats { get }
    var primaryAggregateDeviceID: AudioObjectID { get }
}

extension ProcessTapControlling {
    var primaryAggregateDeviceID: AudioObjectID { .unknown }

    var ioStats: ProcessTapController.IOStats {
        ProcessTapController.IOStats(
            callbackCount: 0,
            totalFrames: 0,
            callbacksPerSecond: 0,
            framesPerCallback: 0,
            inputPeak: 0,
            outputPeaks: [],
            lastCallbackAgo: Double.infinity,
            tapSampleRate: 0
        )
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

    func setLoopbackBuffer(_ buffer: LoopbackRingBuffer?) {
        // Default no-op for mocks that don't override
    }

    var isUnmutedCapture: Bool { false }
}
