// FineTune/Audio/Engine/ProcessTapController.swift
import AudioToolbox
import Foundation
import os

// MARK: - Threading Model
//
// ProcessTapController bridges two execution domains:
//
// 1. **Main thread / @MainActor**: All setup, teardown, and state management.
//    - activate(), invalidate(), updateDevices(), performCrossfadeSwitch()
//    - Property writes to nonisolated(unsafe) vars (_volume, _isMuted, etc.)
//    - This class is NOT @MainActor itself because the HAL I/O callback is not on main.
//
// 2. **HAL I/O thread (real-time)**: Audio processing callbacks.
//    - processAudio(), processAudioSecondary()
//    - Only reads nonisolated(unsafe) vars — never writes except _peakLevel/_secondaryPeakLevel
//    - MUST NOT allocate, lock, log, or call ObjC. See .claude/rules/rt-safety.md
//
// The nonisolated(unsafe) annotation marks variables that cross the thread boundary.
// Aligned Float32/Bool/Int reads/writes are atomic on Apple ARM64/x86-64.

final class ProcessTapController {
    let app: AudioApp
    private let logger: Logger
    // Note: This queue is passed to AudioDeviceCreateIOProcIDWithBlock but the actual
    // audio callback runs on CoreAudio's real-time HAL I/O thread, not this queue.
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)

    /// Weak reference to device monitor for O(1) device lookups during crossfade
    private weak var deviceMonitor: AudioDeviceMonitor?
    /// Optional device UID to use for stream-specific tap capture.
    /// When nil, tap creation always uses stereo mixdown capture.
    private var preferredTapSourceDeviceUID: String?

    // MARK: - RT-Safe State (nonisolated(unsafe) for lock-free audio thread access)
    //
    // These variables are accessed from CoreAudio's real-time thread without locks.
    // SAFETY: Aligned Float32/Bool reads/writes are atomic on Apple ARM/Intel platforms.
    // The audio callback reads these values; the main thread writes them.
    // No lock is needed because single-word aligned loads/stores are atomic.

    /// Target volume set by user (0.0-2.0, where 1.0 = unity gain, 2.0 = +6dB boost)
    private nonisolated(unsafe) var _volume: Float = 1.0
    /// Current ramped volume for primary tap (smoothly approaches _volume)
    private nonisolated(unsafe) var _primaryCurrentVolume: Float = 1.0
    /// Current ramped volume for secondary tap during crossfade
    private nonisolated(unsafe) var _secondaryCurrentVolume: Float = 1.0
    /// Emergency silence flag - zeroes output immediately (used during destructive device switch)
    /// Unlike _isMuted, this bypasses all processing including VU metering
    private nonisolated(unsafe) var _forceSilence: Bool = false
    /// User-controlled mute - still tracks VU levels but outputs silence
    private nonisolated(unsafe) var _isMuted: Bool = false
    // Device volume compensation removed — was dead code (always 1.0).
    // If implementing, ensure both primary and secondary callbacks disable
    // compensation during crossfade to avoid gain jumps (RT-013).
    /// Smoothed peak level for VU meter display (exponential moving average)
    private nonisolated(unsafe) var _peakLevel: Float = 0.0
    /// Separate peak level for secondary tap during crossfade (avoids torn RMW from concurrent callbacks)
    private nonisolated(unsafe) var _secondaryPeakLevel: Float = 0.0
    private nonisolated(unsafe) var _currentDeviceVolume: Float = 1.0
    private nonisolated(unsafe) var _isDeviceMuted: Bool = false
    private nonisolated(unsafe) var _primaryPreferredStereoLeftChannel: Int = 0
    private nonisolated(unsafe) var _primaryPreferredStereoRightChannel: Int = 1
    private nonisolated(unsafe) var _secondaryPreferredStereoLeftChannel: Int = 0
    private nonisolated(unsafe) var _secondaryPreferredStereoRightChannel: Int = 1
    /// Monotonic host tick of the last audio callback execution.
    private nonisolated(unsafe) var _lastRenderHostTime: UInt64 = 0
    /// Monotonic host tick of successful activation.
    private nonisolated(unsafe) var _activationHostTime: UInt64 = 0
    /// Set once any audio callback has rendered at least one buffer.
    private nonisolated(unsafe) var _hasRenderedAudio: Bool = false

    /// Crossfade state machine (RT-safe).
    /// During device switch, we run two taps simultaneously with complementary gain curves:
    /// - Primary uses cos(progress * π/2) → fades from 1.0 to 0.0
    /// - Secondary uses sin(progress * π/2) → fades from 0.0 to 1.0
    /// This "equal power" crossfade maintains perceived loudness throughout the transition.
    /// See CrossfadeState for phase machine details.
    private nonisolated(unsafe) var crossfadeState = CrossfadeState()

    // MARK: - Non-RT State (modified only from main thread)

    /// VU meter smoothing factor. 0.3 gives ~30ms attack/decay at typical 30fps UI refresh.
    /// Lower = smoother but slower response; higher = jittery but more responsive.
    private let levelSmoothingFactor: Float = 0.3
    /// Volume ramp coefficient computed as: 1 - exp(-1 / (sampleRate * rampTime))
    /// Default 0.0007 corresponds to ~30ms ramp at 48kHz. Prevents clicks on volume changes.
    private nonisolated(unsafe) var rampCoefficient: Float = 0.0007
    private nonisolated(unsafe) var secondaryRampCoefficient: Float = 0.0007
    private nonisolated(unsafe) var eqProcessor: EQProcessor?
    private nonisolated(unsafe) var autoEQProcessor: AutoEQProcessor?

    // Target device UIDs for synchronized multi-output (first is clock source)
    private var targetDeviceUIDs: [String]
    // Current active device UIDs
    private(set) var currentDeviceUIDs: [String] = []

    /// Primary device UID (clock source, first in array) - for backward compatibility
    var currentDeviceUID: String? { currentDeviceUIDs.first }

    // Core Audio resources (primary tap) — TapResources enforces correct teardown order
    private var primaryResources = TapResources()
    private var activated = false

    // Secondary tap for crossfade
    private var secondaryResources = TapResources()

    /// Guard against re-entrant crossfade (ORCH-001)
    private var isSwitching = false
    /// Cancellable crossfade task — cancelled when a new switch starts
    private var crossfadeTask: Task<Void, Error>?
    private var didLogEQBypassForMultichannel = false

    // MARK: - Public Properties

    var audioLevel: Float { crossfadeState.isActive ? max(_peakLevel, _secondaryPeakLevel) : _peakLevel }

    private static let hostTimeNanosScale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }()

    /// Returns true when the audio callback has run within the requested interval.
    func hasRecentAudioCallback(within seconds: Double) -> Bool {
        let last = _lastRenderHostTime
        guard last != 0 else { return false }
        let now = mach_absolute_time()
        let deltaNanos = Double(now &- last) * Self.hostTimeNanosScale
        return deltaNanos <= (seconds * 1_000_000_000.0)
    }

    /// Health checks should only run after activation has settled and at least one callback occurred.
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool {
        guard _hasRenderedAudio else { return false }
        let started = _activationHostTime
        guard started != 0 else { return false }
        let deltaNanos = Double(mach_absolute_time() &- started) * Self.hostTimeNanosScale
        return deltaNanos >= (minActiveSeconds * 1_000_000_000.0)
    }

    var currentDeviceVolume: Float {
        get { _currentDeviceVolume }
        set { _currentDeviceVolume = newValue }
    }

    var isDeviceMuted: Bool {
        get { _isDeviceMuted }
        set { _isDeviceMuted = newValue }
    }

    var volume: Float {
        get { _volume }
        set { _volume = newValue }
    }

    var isMuted: Bool {
        get { _isMuted }
        set { _isMuted = newValue }
    }

    // MARK: - Initialization

    /// Initialize with multiple output devices for synchronized multi-device output.
    /// First device in array is the clock source, others have drift compensation enabled.
    init(
        app: AudioApp,
        targetDeviceUIDs: [String],
        deviceMonitor: AudioDeviceMonitor? = nil,
        preferredTapSourceDeviceUID: String? = nil
    ) {
        precondition(!targetDeviceUIDs.isEmpty, "Must have at least one target device")
        self.app = app
        self.targetDeviceUIDs = targetDeviceUIDs
        self.deviceMonitor = deviceMonitor
        self.preferredTapSourceDeviceUID = preferredTapSourceDeviceUID
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    /// Convenience initializer for single device output.
    convenience init(
        app: AudioApp,
        targetDeviceUID: String,
        deviceMonitor: AudioDeviceMonitor? = nil,
        preferredTapSourceDeviceUID: String? = nil
    ) {
        self.init(
            app: app,
            targetDeviceUIDs: [targetDeviceUID],
            deviceMonitor: deviceMonitor,
            preferredTapSourceDeviceUID: preferredTapSourceDeviceUID
        )
    }

    // MARK: - Public Methods

    func updateEQSettings(_ settings: EQSettings) {
        eqProcessor?.updateSettings(settings)
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        autoEQProcessor?.updateProfile(profile)
    }

    // MARK: - Multi-Device Aggregate Configuration

    /// Builds aggregate device description for synchronized multi-device output.
    /// First device is clock source (no drift compensation), others sync to it via drift compensation.
    private func buildAggregateDescription(outputUIDs: [String], tapUUID: UUID, name: String) -> [String: Any] {
        precondition(!outputUIDs.isEmpty, "Must have at least one output device")

        // Build sub-device list - first device is clock source
        var subDevices: [[String: Any]] = []
        for (index, deviceUID) in outputUIDs.enumerated() {
            subDevices.append([
                kAudioSubDeviceUIDKey: deviceUID,
                // First device (index 0) is clock source - no drift compensation needed
                // All other devices have drift compensation enabled to sync to clock
                kAudioSubDeviceDriftCompensationKey: index > 0
            ])
        }

        let clockDeviceUID = outputUIDs[0]  // Primary = clock source

        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,  // All sub-devices receive same audio
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }

    private func preferredStereoChannels(for deviceUID: String?) -> (left: Int, right: Int) {
        guard let deviceUID, let deviceID = audioDeviceID(for: deviceUID) else {
            return (0, 1)
        }
        return deviceID.preferredStereoChannelIndices()
    }

    private func outputStreamIndex(for deviceUID: String?) -> UInt? {
        guard let deviceUID, let deviceID = audioDeviceID(for: deviceUID) else {
            return nil
        }
        return try? deviceID.firstOutputStreamIndex()
    }

    private func audioDeviceID(for deviceUID: String) -> AudioDeviceID? {
        if let monitored = deviceMonitor?.device(for: deviceUID)?.id {
            return monitored
        }

        guard let deviceIDs = try? AudioObjectID.readDeviceList() else { return nil }
        for id in deviceIDs {
            if (try? id.readDeviceUID()) == deviceUID {
                return id
            }
        }
        return nil
    }

    private func maybeLogEQBypass(for tapID: AudioObjectID) {
        guard !didLogEQBypassForMultichannel else { return }
        guard let asbd = try? tapID.readAudioTapStreamBasicDescription() else { return }
        guard asbd.mChannelsPerFrame != 2 else { return }

        didLogEQBypassForMultichannel = true
        logger.info("EQ processing is stereo-only and will be bypassed for tap format with \(asbd.mChannelsPerFrame) channels.")
    }

    /// Creates a process tap, preferring a device-stream tap to preserve multichannel routing.
    /// Falls back to stereo mixdown if stream-specific tap creation fails.
    private func createProcessTap(preferredDeviceUID: String?) throws -> (description: CATapDescription, tapID: AudioObjectID) {
        var lastError: OSStatus = noErr

        if let deviceUID = preferredDeviceUID {
            if let outputStream = outputStreamIndex(for: deviceUID) {
                let streamTap = CATapDescription(processes: app.processObjectIDs, deviceUID: deviceUID, stream: outputStream)
                streamTap.uuid = UUID()
                streamTap.muteBehavior = .mutedWhenTapped

                var tapID: AudioObjectID = .unknown
                let err = AudioHardwareCreateProcessTap(streamTap, &tapID)
                if err == noErr {
                    logger.info("Created stream-specific tap for device \(deviceUID, privacy: .public) (stream \(outputStream))")
                    maybeLogEQBypass(for: tapID)
                    return (streamTap, tapID)
                }

                lastError = err
                logger.warning("Stream-specific tap creation failed for device \(deviceUID, privacy: .public) stream \(outputStream): \(err). Falling back to stereo mixdown.")
            } else {
                logger.warning("Could not resolve an output stream index for device \(deviceUID, privacy: .public). Falling back to stereo mixdown.")
            }
        }

        let mixdownTap = CATapDescription(stereoMixdownOfProcesses: app.processObjectIDs)
        mixdownTap.uuid = UUID()
        mixdownTap.muteBehavior = .mutedWhenTapped

        var mixdownTapID: AudioObjectID = .unknown
        let mixdownErr = AudioHardwareCreateProcessTap(mixdownTap, &mixdownTapID)
        guard mixdownErr == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(mixdownErr),
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create process tap (stream-specific err: \(lastError), mixdown err: \(mixdownErr))"
                ]
            )
        }

        if preferredDeviceUID != nil {
            logger.info("Using stereo mixdown tap fallback")
        }
        maybeLogEQBypass(for: mixdownTapID)
        return (mixdownTap, mixdownTapID)
    }

    func activate() throws {
        guard !activated else { return }

        logger.debug("Activating tap for \(self.app.name)")

        // Reset health tracking for fresh activation
        _lastRenderHostTime = 0
        _activationHostTime = mach_absolute_time()
        _hasRenderedAudio = false

        // Create process tap. Prefer stream-specific tap for multichannel devices to avoid
        // stereo matrix attenuation on interfaces with many output channels.
        let (tapDesc, tapID) = try createProcessTap(preferredDeviceUID: preferredTapSourceDeviceUID)
        primaryResources.tapDescription = tapDesc
        let preferred = preferredStereoChannels(for: targetDeviceUIDs.first)
        _primaryPreferredStereoLeftChannel = preferred.left
        _primaryPreferredStereoRightChannel = preferred.right

        primaryResources.tapID = tapID
        logger.debug("Created process tap #\(tapID)")

        // Build multi-device aggregate description
        // First device is clock source, others have drift compensation for sync
        let description = buildAggregateDescription(
            outputUIDs: targetDeviceUIDs,
            tapUUID: tapDesc.uuid,
            name: "FineTune-\(app.id)"
        )

        var err: OSStatus
        var aggID: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(err)"])
        }
        primaryResources.aggregateDeviceID = aggID
        CrashGuard.trackDevice(aggID)

        guard primaryResources.aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            cleanupPartialActivation()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aggregate device not ready within timeout"])
        }

        logger.debug("Created aggregate device #\(self.primaryResources.aggregateDeviceID)")

        // Compute ramp coefficient from actual device sample rate.
        // Formula: coeff = 1 - exp(-1 / (sampleRate * rampTime))
        // This gives exponential smoothing where the signal reaches ~63% of target in rampTime.
        // 30ms ramp prevents audible clicks when volume changes abruptly.
        let sampleRate: Float64
        if let deviceSampleRate = try? primaryResources.aggregateDeviceID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
            logger.info("Device sample rate: \(sampleRate) Hz")
        } else {
            sampleRate = 48000
            logger.warning("Failed to read sample rate, using default: \(sampleRate) Hz")
        }
        let rampTimeSeconds: Float = 0.030  // 30ms - fast enough to feel responsive, slow enough to avoid clicks
        rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))
        logger.debug("Ramp coefficient: \(self.rampCoefficient)")

        eqProcessor = EQProcessor(sampleRate: sampleRate)
        autoEQProcessor = AutoEQProcessor(sampleRate: sampleRate)

        // Create IO proc with gain processing
        err = AudioDeviceCreateIOProcIDWithBlock(&primaryResources.deviceProcID, primaryResources.aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else {
                // Zero output to prevent garbage audio if controller is deallocated
                let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)
                for buf in outputs {
                    if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
                }
                return
            }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        err = AudioDeviceStart(primaryResources.aggregateDeviceID, primaryResources.deviceProcID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        _primaryCurrentVolume = _volume

        // Track current devices for external queries
        currentDeviceUIDs = targetDeviceUIDs

        activated = true
        logger.info("Tap activated for \(self.app.name) on \(self.targetDeviceUIDs.count) device(s)")
    }

    /// Switch to a single device (convenience for backward compatibility).
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String? = nil) async throws {
        try await updateDevices(to: [newDeviceUID], preferredTapSourceDeviceUID: preferredTapSourceDeviceUID)
    }

    /// Updates output devices using crossfade for seamless transition.
    /// Creates a second tap+aggregate for the new device set, crossfades, then destroys the old one.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String? = nil) async throws {
        precondition(!newDeviceUIDs.isEmpty, "Must have at least one target device")
        self.preferredTapSourceDeviceUID = preferredTapSourceDeviceUID

        guard activated else {
            targetDeviceUIDs = newDeviceUIDs
            return
        }

        guard newDeviceUIDs != currentDeviceUIDs else { return }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("[UPDATE] Switching \(self.app.name) to \(newDeviceUIDs.count) device(s)")

        // For now, crossfade uses the first (primary) device
        // All devices in the aggregate will be included
        let primaryDeviceUID = newDeviceUIDs[0]

        crossfadeTask?.cancel()
        crossfadeTask = Task {
            try await performCrossfadeSwitch(to: primaryDeviceUID, allDeviceUIDs: newDeviceUIDs)
        }
        do {
            try await crossfadeTask!.value
        } catch is CancellationError {
            logger.info("[UPDATE] Crossfade cancelled by invalidate()")
            return
        } catch {
            logger.warning("[UPDATE] Crossfade failed: \(error.localizedDescription), using fallback")
            guard primaryResources.tapDescription != nil else {
                throw CrossfadeError.noTapDescription
            }
            try await performDestructiveDeviceSwitch(to: primaryDeviceUID, allDeviceUIDs: newDeviceUIDs)
        }
        crossfadeTask = nil

        targetDeviceUIDs = newDeviceUIDs
        currentDeviceUIDs = newDeviceUIDs

        let endTime = CFAbsoluteTimeGetCurrent()
        logger.info("[UPDATE] === END === Total time: \((endTime - startTime) * 1000)ms")
    }

    /// Tears down the tap and releases all CoreAudio resources.
    /// Safe to call multiple times - subsequent calls are no-ops.
    private var _invalidating = false
    func invalidate() {
        guard activated, !_invalidating else { return }
        _invalidating = true
        defer { _invalidating = false }
        activated = false

        // Reset health tracking
        _lastRenderHostTime = 0
        _activationHostTime = 0
        _hasRenderedAudio = false

        // Cancel any in-flight crossfade task
        crossfadeTask?.cancel()
        crossfadeTask = nil

        logger.debug("Invalidating tap for \(self.app.name)")

        crossfadeState.complete()

        // destroyAsync() captures IDs, clears instance state immediately,
        // then dispatches blocking teardown to a background queue.
        // Safe even if activate() is called again before cleanup completes.
        secondaryResources.destroyAsync()
        primaryResources.destroyAsync()

        logger.info("Tap invalidated for \(self.app.name)")
    }

    deinit {
        invalidate()
    }

    // MARK: - Crossfade Operations

    private func performCrossfadeSwitch(to primaryDeviceUID: String, allDeviceUIDs: [String]? = nil) async throws {
        let deviceUIDs = allDeviceUIDs ?? [primaryDeviceUID]

        // Re-entrant guard (ORCH-001): if already switching, tear down in-progress secondary
        if isSwitching {
            logger.warning("[CROSSFADE] Re-entrant switch detected — tearing down in-progress secondary")
            cleanupSecondaryTap()
            crossfadeState.complete()
        }
        isSwitching = true
        defer { isSwitching = false }

        logger.info("[CROSSFADE] Step 1: Reading device volumes for compensation")

        var isBluetoothDestination = false
        if let destDevice = deviceMonitor?.device(for: primaryDeviceUID) {
            let transport = destDevice.id.readTransportType()
            isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
            logger.debug("[CROSSFADE] Destination device: BT=\(isBluetoothDestination)")
        }

        logger.info("[CROSSFADE] Step 2: Preparing crossfade state")

        // Enter warmingUp phase before tap creation so audio callbacks see correct state.
        // totalSamples is set inside createSecondaryTap after reading sample rate.
        crossfadeState.beginWarmup()

        logger.info("[CROSSFADE] Step 3: Creating secondary tap for \(deviceUIDs.count) device(s)")
        try createSecondaryTap(for: deviceUIDs)

        // LIFE-004/005: Ensure secondary tap is cleaned up if crossfade fails or is cancelled
        var crossfadeCompleted = false
        defer {
            if !crossfadeCompleted {
                logger.warning("[CROSSFADE] Cleaning up secondary tap after failure/cancellation")
                cleanupSecondaryTap()
                crossfadeState.complete()
            }
        }

        if isBluetoothDestination {
            logger.info("[CROSSFADE] Destination is Bluetooth - using extended warmup")
        }

        let warmupMs = isBluetoothDestination ? 300 : 50
        logger.info("[CROSSFADE] Step 4: Waiting for secondary tap warmup (\(warmupMs)ms)...")
        try await Task.sleep(for: .milliseconds(UInt64(warmupMs)))

        // Transition to crossfading phase now that warmup sleep has elapsed
        crossfadeState.beginCrossfading()
        logger.info("[CROSSFADE] Step 5: Crossfade in progress (\(CrossfadeConfig.duration * 1000)ms)")

        let timeoutMs = Int(CrossfadeConfig.duration * 1000) + (isBluetoothDestination ? 400 : 100)
        let pollIntervalMs: UInt64 = 5
        var elapsedMs: Int = 0

        while (!crossfadeState.isCrossfadeComplete || !crossfadeState.isWarmupComplete) && elapsedMs < timeoutMs {
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
            elapsedMs += Int(pollIntervalMs)
        }

        // Handle timeout - force completion if progress incomplete
        let progressAtTimeout = crossfadeState.progress
        if progressAtTimeout < 1.0 {
            logger.warning("[CROSSFADE] Timeout at \(progressAtTimeout * 100)% - forcing completion")
            crossfadeState.progress = 1.0
        }

        // Verify secondary tap is valid before promotion
        guard secondaryResources.aggregateDeviceID.isValid, secondaryResources.deviceProcID != nil else {
            logger.error("[CROSSFADE] Secondary tap invalid after timeout")
            // defer will handle cleanup (cleanupSecondaryTap + crossfadeState.complete)
            throw CrossfadeError.secondaryTapFailed
        }

        try await Task.sleep(for: .milliseconds(10))

        logger.info("[CROSSFADE] Crossfade complete, promoting secondary")

        destroyPrimaryTap()
        promoteSecondaryToPrimary()

        crossfadeState.complete()
        crossfadeCompleted = true

        logger.info("[CROSSFADE] Complete")
    }

    private func createSecondaryTap(for outputUIDs: [String]) throws {
        precondition(!outputUIDs.isEmpty, "Must have at least one output device")

        let (tapDesc, tapID) = try createProcessTap(preferredDeviceUID: preferredTapSourceDeviceUID)
        secondaryResources.tapDescription = tapDesc
        let preferred = preferredStereoChannels(for: outputUIDs.first)
        _secondaryPreferredStereoLeftChannel = preferred.left
        _secondaryPreferredStereoRightChannel = preferred.right

        secondaryResources.tapID = tapID
        logger.debug("[CROSSFADE] Created secondary tap #\(tapID)")

        // Build multi-device aggregate description using helper
        let description = buildAggregateDescription(
            outputUIDs: outputUIDs,
            tapUUID: tapDesc.uuid,
            name: "FineTune-\(app.id)-secondary"
        )

        var err: OSStatus
        var aggID: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard err == noErr else {
            // TapResources.destroy() handles correct teardown order + CrashGuard.untrackDevice
            secondaryResources.destroy()
            throw CrossfadeError.aggregateCreationFailed(err)
        }
        secondaryResources.aggregateDeviceID = aggID
        CrashGuard.trackDevice(aggID)

        guard secondaryResources.aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            secondaryResources.destroy()
            throw CrossfadeError.deviceNotReady
        }

        logger.debug("[CROSSFADE] Created secondary aggregate #\(self.secondaryResources.aggregateDeviceID)")

        let sampleRate: Double
        if let deviceSampleRate = try? secondaryResources.aggregateDeviceID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
        } else {
            sampleRate = 48000
        }
        crossfadeState.totalSamples = CrossfadeConfig.totalSamples(at: sampleRate)

        let rampTimeSeconds: Float = 0.030
        secondaryRampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))

        _secondaryCurrentVolume = _primaryCurrentVolume

        err = AudioDeviceCreateIOProcIDWithBlock(&secondaryResources.deviceProcID, secondaryResources.aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else {
                // Zero output to prevent garbage audio if controller is deallocated
                let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)
                for buf in outputs {
                    if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
                }
                return
            }
            self.processAudioSecondary(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            secondaryResources.destroy()
            throw CrossfadeError.tapCreationFailed(err)
        }

        err = AudioDeviceStart(secondaryResources.aggregateDeviceID, secondaryResources.deviceProcID)
        guard err == noErr else {
            secondaryResources.destroy()
            throw CrossfadeError.tapCreationFailed(err)
        }

        logger.debug("[CROSSFADE] Secondary tap started")
    }

    private func destroyPrimaryTap() {
        primaryResources.destroyAsync()
    }

    /// Tears down any in-progress secondary tap (used by re-entrant crossfade guard).
    private func cleanupSecondaryTap() {
        guard secondaryResources.isActive else { return }
        secondaryResources.destroy()
    }

    private func promoteSecondaryToPrimary() {
        primaryResources = secondaryResources
        secondaryResources = TapResources()

        if let deviceSampleRate = try? primaryResources.aggregateDeviceID.readNominalSampleRate() {
            let rampTimeSeconds: Float = 0.030
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * rampTimeSeconds))
            eqProcessor?.updateSampleRate(deviceSampleRate)
            autoEQProcessor?.updateSampleRate(deviceSampleRate)
        }

        _primaryCurrentVolume = _secondaryCurrentVolume
        _secondaryCurrentVolume = 0
        _primaryPreferredStereoLeftChannel = _secondaryPreferredStereoLeftChannel
        _primaryPreferredStereoRightChannel = _secondaryPreferredStereoRightChannel

        // CrossfadeState reset is handled by the caller (performCrossfadeSwitch calls complete())
    }

    private func performDestructiveDeviceSwitch(to primaryDeviceUID: String, allDeviceUIDs: [String]? = nil) async throws {
        let deviceUIDs = allDeviceUIDs ?? [primaryDeviceUID]
        let originalVolume = _volume

        _forceSilence = true
        OSMemoryBarrier()
        // LIFE-011: Ensure _forceSilence is always cleared, even if switch throws
        defer { _forceSilence = false; OSMemoryBarrier() }
        logger.info("[SWITCH-DESTROY] Enabled _forceSilence=true")

        try await Task.sleep(for: .milliseconds(100))

        try performDeviceSwitch(to: deviceUIDs)

        _primaryCurrentVolume = 0
        _volume = 0

        try await Task.sleep(for: .milliseconds(150))

        _forceSilence = false

        for i in 1...10 {
            _volume = originalVolume * Float(i) / 10.0
            try await Task.sleep(for: .milliseconds(20))
        }

        logger.info("[SWITCH-DESTROY] Complete")
    }

    private func performDeviceSwitch(to outputUIDs: [String]) throws {
        precondition(!outputUIDs.isEmpty, "Must have at least one output device")

        var newResources = TapResources()

        let (newTapDesc, tapID) = try createProcessTap(preferredDeviceUID: preferredTapSourceDeviceUID)
        newResources.tapDescription = newTapDesc
        // SAFETY: _forceSilence must be true before reaching here (set by performDestructiveDeviceSwitch).
        // The old IO proc is still running until primaryResources.destroy() below, but _forceSilence
        // causes processAudio() to return early, so these writes won't race with processMappedBuffers().
        let preferred = preferredStereoChannels(for: outputUIDs.first)
        _primaryPreferredStereoLeftChannel = preferred.left
        _primaryPreferredStereoRightChannel = preferred.right

        newResources.tapID = tapID

        // Build multi-device aggregate description using helper
        let description = buildAggregateDescription(
            outputUIDs: outputUIDs,
            tapUUID: newTapDesc.uuid,
            name: "FineTune-\(app.id)"
        )

        var err: OSStatus
        var aggID: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard err == noErr else {
            newResources.destroy()
            throw CrossfadeError.aggregateCreationFailed(err)
        }
        newResources.aggregateDeviceID = aggID
        CrashGuard.trackDevice(aggID)

        guard newResources.aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            newResources.destroy()
            throw CrossfadeError.deviceNotReady
        }

        err = AudioDeviceCreateIOProcIDWithBlock(&newResources.deviceProcID, newResources.aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else {
                // Zero output to prevent garbage audio if controller is deallocated
                let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)
                for buf in outputs {
                    if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
                }
                return
            }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            newResources.destroy()
            throw CrossfadeError.tapCreationFailed(err)
        }

        err = AudioDeviceStart(newResources.aggregateDeviceID, newResources.deviceProcID)
        guard err == noErr else {
            newResources.destroy()
            throw CrossfadeError.tapCreationFailed(err)
        }

        // Destroy old resources, adopt new
        primaryResources.destroy()
        primaryResources = newResources
        targetDeviceUIDs = outputUIDs
        currentDeviceUIDs = outputUIDs

        if let deviceSampleRate = try? primaryResources.aggregateDeviceID.readNominalSampleRate() {
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * 0.030))
            eqProcessor?.updateSampleRate(deviceSampleRate)
            autoEQProcessor?.updateSampleRate(deviceSampleRate)
        }
    }

    private func cleanupPartialActivation() {
        primaryResources.destroy()
    }

    @inline(__always)
    private func processMappedBuffers(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        targetVol: Float,
        crossfadeMultiplier: Float,
        rampCoefficient: Float,
        preferredStereoLeft: Int,
        preferredStereoRight: Int,
        currentVol: inout Float
    ) {
        let inputBufferCount = inputBuffers.count
        let outputBufferCount = outputBuffers.count

        for outputIndex in 0..<outputBufferCount {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            let inputIndex: Int
            if inputBufferCount > outputBufferCount {
                inputIndex = inputBufferCount - outputBufferCount + outputIndex
            } else {
                inputIndex = outputIndex
            }

            guard inputIndex < inputBufferCount else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputBuffer = inputBuffers[inputIndex]
            guard let inputData = inputBuffer.mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let inputChannels = max(1, Int(inputBuffer.mNumberChannels))
            let outputChannels = max(1, Int(outputBuffer.mNumberChannels))
            let inputSampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let outputSampleCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let inputFrameCount = inputSampleCount / inputChannels
            let outputFrameCount = outputSampleCount / outputChannels
            let frameCount = min(inputFrameCount, outputFrameCount)

            guard frameCount > 0 else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let safeLeft = min(max(preferredStereoLeft, 0), max(outputChannels - 1, 0))
            let safeRight = min(max(preferredStereoRight, 0), max(outputChannels - 1, 0))

            let eq = eqProcessor  // Single atomic read — prevents TOCTOU with EQ check below
            let eqCanProcessStereoInterleaved = (inputChannels == 2 && outputChannels == 2)
            let preamp: Float = (eq?.isEnabled == true && eqCanProcessStereoInterleaved && !crossfadeState.isActive) ? (eq?.preampAttenuation ?? 1.0) : 1.0

            if inputChannels == outputChannels {
                let sampleCount = frameCount * inputChannels
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier * preamp
                    let base = frame * inputChannels
                    for ch in 0..<inputChannels {
                        outputSamples[base + ch] = inputSamples[base + ch] * gain
                    }
                }
                if sampleCount < outputSampleCount {
                    memset(outputSamples.advanced(by: sampleCount), 0, (outputSampleCount - sampleCount) * MemoryLayout<Float>.size)
                }
            } else if inputChannels == 2 && outputChannels > 2 {
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier * preamp
                    let inBase = frame * 2
                    let outBase = frame * outputChannels
                    let left = inputSamples[inBase] * gain
                    let right = inputSamples[inBase + 1] * gain

                    for ch in 0..<outputChannels {
                        outputSamples[outBase + ch] = 0
                    }
                    outputSamples[outBase + safeLeft] = left
                    outputSamples[outBase + safeRight] = right
                }
                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            } else if inputChannels == 1 && outputChannels > 1 {
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier * preamp
                    let sample = inputSamples[frame] * gain
                    let outBase = frame * outputChannels

                    for ch in 0..<outputChannels {
                        outputSamples[outBase + ch] = 0
                    }
                    outputSamples[outBase + safeLeft] = sample
                    outputSamples[outBase + safeRight] = sample
                }
                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            } else {
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier * preamp
                    let inBase = frame * inputChannels
                    let outBase = frame * outputChannels
                    let copiedChannels = min(inputChannels, outputChannels)
                    for ch in 0..<copiedChannels {
                        outputSamples[outBase + ch] = inputSamples[inBase + ch] * gain
                    }
                    if copiedChannels < outputChannels {
                        for ch in copiedChannels..<outputChannels {
                            outputSamples[outBase + ch] = 0
                        }
                    }
                }
                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            }

            if let eq = eq, eq.isEnabled, eqCanProcessStereoInterleaved, !crossfadeState.isActive {
                eq.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
            }

            // Per-device AutoEQ correction (after per-app EQ)
            let autoEQ = autoEQProcessor
            if let autoEQ, autoEQ.isEnabled, eqCanProcessStereoInterleaved, !crossfadeState.isActive {
                autoEQ.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
            }

            let writtenSampleCount = frameCount * outputChannels
            SoftLimiter.processBuffer(outputSamples, sampleCount: writtenSampleCount)
        }
    }

    // MARK: - RT-Safe Audio Callbacks (DO NOT MODIFY WITHOUT RT-SAFETY REVIEW)
    // These callbacks run on CoreAudio's real-time HAL I/O thread.
    // See .claude/rules/rt-safety.md for constraints.

    /// Audio processing callback for PRIMARY tap.
    /// **RT SAFETY CONSTRAINTS - DO NOT:**
    /// - Allocate memory (malloc, Array append, String operations)
    /// - Acquire locks/mutexes
    /// - Use Objective-C messaging
    /// - Call print/logging functions
    /// - Perform file/network I/O
    private func processAudio(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        _lastRenderHostTime = mach_absolute_time()
        _hasRenderedAudio = true

        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        // SAFETY: Mutable cast required by UnsafeMutableAudioBufferListPointer API,
        // but we only read through this pointer. Input buffer data is owned by CoreAudio
        // and valid for callback duration.
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        if _forceSilence {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        // Track peak level for VU meter
        var maxPeak: Float = 0.0
        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData else { continue }
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let channels = max(1, Int(inputBuffer.mNumberChannels))
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in stride(from: 0, to: sampleCount, by: channels) {
                let absSample = abs(inputSamples[i])
                if absSample > maxPeak {
                    maxPeak = absSample
                }
            }
        }
        let rawPeak = min(maxPeak, 1.0)
        _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)

        if _isMuted {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        let targetVol = _volume
        var currentVol = _primaryCurrentVolume

        // Equal-power crossfade: primary uses cosine curve (1→0), secondary uses sine curve (0→1)
        // cos²(x) + sin²(x) = 1, so total power remains constant throughout transition.
        // CrossfadeState.primaryMultiplier handles all phase logic including the race condition
        // guard (returns 0.0 when progress >= 1.0 in idle phase after crossfade completes).
        let crossfadeMultiplier = crossfadeState.primaryMultiplier

        processMappedBuffers(
            inputBuffers: inputBuffers,
            outputBuffers: outputBuffers,
            targetVol: targetVol,
            crossfadeMultiplier: crossfadeMultiplier,
            rampCoefficient: rampCoefficient,
            preferredStereoLeft: _primaryPreferredStereoLeftChannel,
            preferredStereoRight: _primaryPreferredStereoRightChannel,
            currentVol: &currentVol
        )

        _primaryCurrentVolume = currentVol
    }

    /// Audio processing callback for SECONDARY tap during crossfade.
    private func processAudioSecondary(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        _lastRenderHostTime = mach_absolute_time()
        _hasRenderedAudio = true

        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        // SAFETY: Mutable cast required by UnsafeMutableAudioBufferListPointer API,
        // but we only read through this pointer. Input buffer data is owned by CoreAudio
        // and valid for callback duration.
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        var maxPeak: Float = 0.0
        var totalSamplesThisBuffer: Int = 0
        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData else { continue }
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let channels = max(1, Int(inputBuffer.mNumberChannels))
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            if totalSamplesThisBuffer == 0 {
                totalSamplesThisBuffer = sampleCount / channels
            }
            for i in stride(from: 0, to: sampleCount, by: channels) {
                let absSample = abs(inputSamples[i])
                if absSample > maxPeak {
                    maxPeak = absSample
                }
            }
        }
        let rawPeak = min(maxPeak, 1.0)
        _secondaryPeakLevel = _secondaryPeakLevel + levelSmoothingFactor * (rawPeak - _secondaryPeakLevel)

        // Update crossfade progress via state machine (handles sample counting + phase logic)
        _ = crossfadeState.updateProgress(samples: totalSamplesThisBuffer)

        if _isMuted {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        let targetVol = _volume
        var currentVol = _secondaryCurrentVolume

        // CrossfadeState.secondaryMultiplier handles all phase logic:
        // .warmingUp → 0.0 (muted), .crossfading → sin(progress*π/2), .idle → 1.0
        let crossfadeMultiplier = crossfadeState.secondaryMultiplier

        processMappedBuffers(
            inputBuffers: inputBuffers,
            outputBuffers: outputBuffers,
            targetVol: targetVol,
            crossfadeMultiplier: crossfadeMultiplier,
            rampCoefficient: secondaryRampCoefficient,
            preferredStereoLeft: _secondaryPreferredStereoLeftChannel,
            preferredStereoRight: _secondaryPreferredStereoRightChannel,
            currentVol: &currentVol
        )

        _secondaryCurrentVolume = currentVol
    }
}
