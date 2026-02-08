// FineTune/Audio/ProcessTapController.swift
import AudioToolbox
import os

final class ProcessTapController {
    let app: AudioApp
    private let logger: Logger
    // Note: This queue is passed to AudioDeviceCreateIOProcIDWithBlock but the actual
    // audio callback runs on CoreAudio's real-time HAL I/O thread, not this queue.
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)

    /// Weak reference to device monitor for O(1) device lookups during crossfade
    private weak var deviceMonitor: AudioDeviceMonitor?

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
    /// Compensation factor when device volume < 100% (preserves user's relative mix)
    private nonisolated(unsafe) var _deviceVolumeCompensation: Float = 1.0
    /// Smoothed peak level for VU meter display (exponential moving average)
    private nonisolated(unsafe) var _peakLevel: Float = 0.0
    private nonisolated(unsafe) var _currentDeviceVolume: Float = 1.0
    private nonisolated(unsafe) var _isDeviceMuted: Bool = false

    // Crossfade state (RT-safe)
    // During device switch, we run two taps simultaneously with complementary gain curves:
    // - Primary uses cos(progress * π/2) → fades from 1.0 to 0.0
    // - Secondary uses sin(progress * π/2) → fades from 0.0 to 1.0
    // This "equal power" crossfade maintains perceived loudness throughout the transition.
    private nonisolated(unsafe) var _crossfadeProgress: Float = 0
    private nonisolated(unsafe) var _isCrossfading: Bool = false
    /// Sample count in secondary tap - used for sample-accurate crossfade timing
    private nonisolated(unsafe) var _secondarySampleCount: Int64 = 0
    private nonisolated(unsafe) var _crossfadeTotalSamples: Int64 = 0
    /// Warmup sample count - ensures secondary tap has produced audio before promotion
    /// 2048 samples ≈ 43ms at 48kHz - enough for buffer priming
    private nonisolated(unsafe) var _secondarySamplesProcessed: Int = 0

    // MARK: - Non-RT State (modified only from main thread)

    /// VU meter smoothing factor. 0.3 gives ~30ms attack/decay at typical 30fps UI refresh.
    /// Lower = smoother but slower response; higher = jittery but more responsive.
    private let levelSmoothingFactor: Float = 0.3
    /// Volume ramp coefficient computed as: 1 - exp(-1 / (sampleRate * rampTime))
    /// Default 0.0007 corresponds to ~30ms ramp at 48kHz. Prevents clicks on volume changes.
    private var rampCoefficient: Float = 0.0007
    private var secondaryRampCoefficient: Float = 0.0007
    /// Minimum samples secondary tap must process before we trust its output.
    /// 2048 samples ≈ 43ms at 48kHz - accounts for audio buffer priming.
    private let minimumWarmupSamples: Int = 2048

    private var eqProcessor: EQProcessor?

    // Target device UIDs for synchronized multi-output (first is clock source)
    private var targetDeviceUIDs: [String]
    // Current active device UIDs
    private(set) var currentDeviceUIDs: [String] = []

    /// Primary device UID (clock source, first in array) - for backward compatibility
    var currentDeviceUID: String? { currentDeviceUIDs.first }

    // Core Audio state (primary tap)
    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var activated = false

    // Secondary tap for crossfade
    private var secondaryTapID: AudioObjectID = .unknown
    private var secondaryAggregateID: AudioObjectID = .unknown
    private var secondaryDeviceProcID: AudioDeviceIOProcID?
    private var secondaryTapDescription: CATapDescription?

    // Sample rate change detection (Bluetooth HFP profile switches)
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Callback invoked when the aggregate device's sample rate changes (e.g., Bluetooth HFP switch).
    /// AudioEngine uses this to trigger a tap rebuild with correct parameters.
    var onSampleRateChanged: (() -> Void)?
    /// Tracks the sample rate the tap was configured with, to detect actual changes.
    private var activeSampleRate: Float64 = 0

    // MARK: - Public Properties

    var audioLevel: Float { _peakLevel }

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
    init(app: AudioApp, targetDeviceUIDs: [String], deviceMonitor: AudioDeviceMonitor? = nil) {
        precondition(!targetDeviceUIDs.isEmpty, "Must have at least one target device")
        self.app = app
        self.targetDeviceUIDs = targetDeviceUIDs
        self.deviceMonitor = deviceMonitor
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    /// Convenience initializer for single device output.
    convenience init(app: AudioApp, targetDeviceUID: String, deviceMonitor: AudioDeviceMonitor? = nil) {
        self.init(app: app, targetDeviceUIDs: [targetDeviceUID], deviceMonitor: deviceMonitor)
    }

    // MARK: - Public Methods

    func updateEQSettings(_ settings: EQSettings) {
        eqProcessor?.updateSettings(settings)
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

    func activate() throws {
        guard !activated else { return }

        logger.debug("Activating tap for \(self.app.name)")

        // Create process tap
        // CATapDescription produces stereo Float32 interleaved audio from the target process.
        // mutedWhenTapped ensures the app's audio goes through our tap, not directly to output.
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped
        self.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        processTapID = tapID
        logger.debug("Created process tap #\(tapID)")

        // Build multi-device aggregate description
        // First device is clock source, others have drift compensation for sync
        let description = buildAggregateDescription(
            outputUIDs: targetDeviceUIDs,
            tapUUID: tapDesc.uuid,
            name: "FineTune-\(app.id)"
        )

        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(err)"])
        }

        guard aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            cleanupPartialActivation()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aggregate device not ready within timeout"])
        }

        logger.debug("Created aggregate device #\(self.aggregateDeviceID)")

        // Compute ramp coefficient from actual device sample rate.
        // Formula: coeff = 1 - exp(-1 / (sampleRate * rampTime))
        // This gives exponential smoothing where the signal reaches ~63% of target in rampTime.
        // 30ms ramp prevents audible clicks when volume changes abruptly.
        let sampleRate: Float64
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
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

        // Create IO proc with gain processing
        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        _primaryCurrentVolume = _volume
        _deviceVolumeCompensation = 1.0

        // Track current devices for external queries
        currentDeviceUIDs = targetDeviceUIDs

        // Track active sample rate for change detection
        activeSampleRate = sampleRate

        // Listen for sample rate changes on the aggregate device.
        // This catches Bluetooth HFP profile switches (48kHz → 8/16kHz) that would
        // otherwise cause high-pitched distorted audio from sample rate mismatch.
        installSampleRateListener(on: aggregateDeviceID)

        activated = true
        logger.info("Tap activated for \(self.app.name) on \(self.targetDeviceUIDs.count) device(s)")
    }

    /// Forces a destructive rebuild of the tap on the current devices.
    /// Used when the device sample rate changes (e.g., Bluetooth HFP profile switch)
    /// and the existing tap needs to be recreated with correct parameters.
    func rebuildTap() async throws {
        guard activated, !currentDeviceUIDs.isEmpty else { return }
        let deviceUIDs = currentDeviceUIDs
        logger.info("Rebuilding tap for \(self.app.name) due to sample rate change")
        try await performDestructiveDeviceSwitch(to: deviceUIDs[0], allDeviceUIDs: deviceUIDs)
    }

    /// Switch to a single device (convenience for backward compatibility).
    func switchDevice(to newDeviceUID: String) async throws {
        try await updateDevices(to: [newDeviceUID])
    }

    /// Updates output devices using crossfade for seamless transition.
    /// Creates a second tap+aggregate for the new device set, crossfades, then destroys the old one.
    func updateDevices(to newDeviceUIDs: [String]) async throws {
        precondition(!newDeviceUIDs.isEmpty, "Must have at least one target device")

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

        do {
            try await performCrossfadeSwitch(to: primaryDeviceUID, allDeviceUIDs: newDeviceUIDs)
        } catch {
            logger.warning("[UPDATE] Crossfade failed: \(error.localizedDescription), using fallback")
            guard tapDescription != nil else {
                throw CrossfadeError.noTapDescription
            }
            try await performDestructiveDeviceSwitch(to: primaryDeviceUID, allDeviceUIDs: newDeviceUIDs)
        }

        targetDeviceUIDs = newDeviceUIDs
        currentDeviceUIDs = newDeviceUIDs

        let endTime = CFAbsoluteTimeGetCurrent()
        logger.info("[UPDATE] === END === Total time: \((endTime - startTime) * 1000)ms")
    }

    /// Tears down the tap and releases all CoreAudio resources.
    /// Safe to call multiple times - subsequent calls are no-ops.
    func invalidate() {
        guard activated else { return }
        activated = false

        logger.debug("Invalidating tap for \(self.app.name)")

        removeSampleRateListener()
        _isCrossfading = false

        // SAFE CLEANUP PATTERN: Capture IDs before clearing instance state.
        // The dispatched cleanup uses these captured values, not instance variables.
        // This is safe even if activate() is called again before cleanup completes,
        // because new activation creates new IDs that won't be affected.
        let primaryAggregate = aggregateDeviceID
        let primaryProcID = deviceProcID
        let primaryTap = processTapID
        let secAggregate = secondaryAggregateID
        let secProcID = secondaryDeviceProcID
        let secTap = secondaryTapID

        // Clear instance state immediately
        aggregateDeviceID = .unknown
        deviceProcID = nil
        processTapID = .unknown
        secondaryAggregateID = .unknown
        secondaryDeviceProcID = nil
        secondaryTapID = .unknown
        secondaryTapDescription = nil

        // Dispatch blocking teardown to background queue
        DispatchQueue.global(qos: .utility).async {
            CrossfadeOrchestrator.destroyTap(aggregateID: secAggregate, deviceProcID: secProcID, tapID: secTap)
            CrossfadeOrchestrator.destroyTap(aggregateID: primaryAggregate, deviceProcID: primaryProcID, tapID: primaryTap)
        }

        logger.info("Tap invalidated for \(self.app.name)")
    }

    deinit {
        invalidate()
    }

    // MARK: - Sample Rate Change Detection

    private func installSampleRateListener(on deviceID: AudioObjectID) {
        removeSampleRateListener()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newRate = (try? deviceID.readNominalSampleRate()) ?? 0
            guard newRate > 0, newRate != self.activeSampleRate else { return }
            self.logger.warning("Sample rate changed: \(self.activeSampleRate)Hz → \(newRate)Hz (Bluetooth profile switch?)")
            self.activeSampleRate = newRate
            self.onSampleRateChanged?()
        }
        sampleRateListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &sampleRateAddress,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            logger.error("Failed to add sample rate listener: \(status)")
        }
    }

    private func removeSampleRateListener() {
        guard let block = sampleRateListenerBlock else { return }
        // Remove from both primary and secondary aggregate (one will be valid)
        if aggregateDeviceID.isValid {
            AudioObjectRemovePropertyListenerBlock(aggregateDeviceID, &sampleRateAddress, DispatchQueue.main, block)
        }
        sampleRateListenerBlock = nil
    }

    // MARK: - Crossfade Operations

    private func performCrossfadeSwitch(to primaryDeviceUID: String, allDeviceUIDs: [String]? = nil) async throws {
        let deviceUIDs = allDeviceUIDs ?? [primaryDeviceUID]

        logger.info("[CROSSFADE] Step 1: Reading device volumes for compensation")

        var isBluetoothDestination = false
        if let destDevice = deviceMonitor?.device(for: primaryDeviceUID) {
            let transport = destDevice.id.readTransportType()
            isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
            logger.debug("[CROSSFADE] Destination device: BT=\(isBluetoothDestination)")
        }

        logger.info("[CROSSFADE] Step 2: Preparing crossfade state")

        _crossfadeProgress = 0
        _secondarySampleCount = 0
        _secondarySamplesProcessed = 0
        _isCrossfading = true

        logger.info("[CROSSFADE] Step 3: Creating secondary tap for \(deviceUIDs.count) device(s)")
        try createSecondaryTap(for: deviceUIDs)

        if isBluetoothDestination {
            logger.info("[CROSSFADE] Destination is Bluetooth - using extended warmup")
        }

        let warmupMs = isBluetoothDestination ? 300 : 50
        logger.info("[CROSSFADE] Step 4: Waiting for secondary tap warmup (\(warmupMs)ms)...")
        try await Task.sleep(for: .milliseconds(UInt64(warmupMs)))

        logger.info("[CROSSFADE] Step 5: Crossfade in progress (\(CrossfadeConfig.duration * 1000)ms)")

        let timeoutMs = Int(CrossfadeConfig.duration * 1000) + (isBluetoothDestination ? 400 : 100)
        let pollIntervalMs: UInt64 = 5
        var elapsedMs: Int = 0

        while (_crossfadeProgress < 1.0 || _secondarySamplesProcessed < minimumWarmupSamples) && elapsedMs < timeoutMs {
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
            elapsedMs += Int(pollIntervalMs)
        }

        // Handle timeout - force completion if progress incomplete
        let progressAtTimeout = _crossfadeProgress
        if progressAtTimeout < 1.0 {
            logger.warning("[CROSSFADE] Timeout at \(progressAtTimeout * 100)% - forcing completion")
            _crossfadeProgress = 1.0
        }

        // Verify secondary tap is valid before promotion
        guard secondaryAggregateID.isValid, secondaryDeviceProcID != nil else {
            logger.error("[CROSSFADE] Secondary tap invalid after timeout")
            _isCrossfading = false
            throw CrossfadeError.secondaryTapFailed
        }

        try await Task.sleep(for: .milliseconds(10))

        logger.info("[CROSSFADE] Crossfade complete, promoting secondary")

        destroyPrimaryTap()
        promoteSecondaryToPrimary()

        _isCrossfading = false

        logger.info("[CROSSFADE] Complete")
    }

    private func createSecondaryTap(for outputUIDs: [String]) throws {
        precondition(!outputUIDs.isEmpty, "Must have at least one output device")

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped
        secondaryTapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw CrossfadeError.tapCreationFailed(err)
        }
        secondaryTapID = tapID
        logger.debug("[CROSSFADE] Created secondary tap #\(tapID)")

        // Build multi-device aggregate description using helper
        let description = buildAggregateDescription(
            outputUIDs: outputUIDs,
            tapUUID: tapDesc.uuid,
            name: "FineTune-\(app.id)-secondary"
        )

        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &secondaryAggregateID)
        guard err == noErr else {
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryTapID = .unknown
            throw CrossfadeError.aggregateCreationFailed(err)
        }

        guard secondaryAggregateID.waitUntilReady(timeout: 2.0) else {
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryAggregateID = .unknown
            secondaryTapID = .unknown
            throw CrossfadeError.deviceNotReady
        }

        logger.debug("[CROSSFADE] Created secondary aggregate #\(self.secondaryAggregateID)")

        let sampleRate: Double
        if let deviceSampleRate = try? secondaryAggregateID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
        } else {
            sampleRate = 48000
        }
        _crossfadeTotalSamples = CrossfadeConfig.totalSamples(at: sampleRate)

        let rampTimeSeconds: Float = 0.030
        secondaryRampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))

        _secondaryCurrentVolume = _primaryCurrentVolume

        err = AudioDeviceCreateIOProcIDWithBlock(&secondaryDeviceProcID, secondaryAggregateID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudioSecondary(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryAggregateID = .unknown
            secondaryTapID = .unknown
            throw CrossfadeError.tapCreationFailed(err)
        }

        err = AudioDeviceStart(secondaryAggregateID, secondaryDeviceProcID)
        guard err == noErr else {
            if let procID = secondaryDeviceProcID {
                AudioDeviceDestroyIOProcID(secondaryAggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryDeviceProcID = nil
            secondaryAggregateID = .unknown
            secondaryTapID = .unknown
            throw CrossfadeError.tapCreationFailed(err)
        }

        logger.debug("[CROSSFADE] Secondary tap started")
    }

    private func destroyPrimaryTap() {
        CrossfadeOrchestrator.destroyTap(aggregateID: aggregateDeviceID, deviceProcID: deviceProcID, tapID: processTapID)
        deviceProcID = nil
        aggregateDeviceID = .unknown
        processTapID = .unknown
        tapDescription = nil
    }

    private func promoteSecondaryToPrimary() {
        processTapID = secondaryTapID
        aggregateDeviceID = secondaryAggregateID
        deviceProcID = secondaryDeviceProcID
        tapDescription = secondaryTapDescription

        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            let rampTimeSeconds: Float = 0.030
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * rampTimeSeconds))
            eqProcessor?.updateSampleRate(deviceSampleRate)
            activeSampleRate = deviceSampleRate
        }

        installSampleRateListener(on: aggregateDeviceID)

        _primaryCurrentVolume = _secondaryCurrentVolume
        _secondaryCurrentVolume = 0

        _crossfadeProgress = 0
        _secondarySampleCount = 0
        _crossfadeTotalSamples = 0

        secondaryTapID = .unknown
        secondaryAggregateID = .unknown
        secondaryDeviceProcID = nil
        secondaryTapDescription = nil
    }

    private func performDestructiveDeviceSwitch(to primaryDeviceUID: String, allDeviceUIDs: [String]? = nil) async throws {
        let deviceUIDs = allDeviceUIDs ?? [primaryDeviceUID]
        let originalVolume = _volume

        _forceSilence = true
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

        let newTapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        newTapDesc.uuid = UUID()
        newTapDesc.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(newTapDesc, &newTapID)
        guard err == noErr else {
            throw CrossfadeError.tapCreationFailed(err)
        }

        // Build multi-device aggregate description using helper
        let description = buildAggregateDescription(
            outputUIDs: outputUIDs,
            tapUUID: newTapDesc.uuid,
            name: "FineTune-\(app.id)"
        )

        var newAggregateID: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw CrossfadeError.aggregateCreationFailed(err)
        }

        guard newAggregateID.waitUntilReady(timeout: 2.0) else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw CrossfadeError.deviceNotReady
        }

        var newDeviceProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newDeviceProcID, newAggregateID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw CrossfadeError.tapCreationFailed(err)
        }

        err = AudioDeviceStart(newAggregateID, newDeviceProcID)
        guard err == noErr else {
            if let procID = newDeviceProcID {
                AudioDeviceDestroyIOProcID(newAggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw CrossfadeError.tapCreationFailed(err)
        }

        CrossfadeOrchestrator.destroyTap(aggregateID: aggregateDeviceID, deviceProcID: deviceProcID, tapID: processTapID)

        processTapID = newTapID
        tapDescription = newTapDesc
        aggregateDeviceID = newAggregateID
        deviceProcID = newDeviceProcID
        targetDeviceUIDs = outputUIDs
        currentDeviceUIDs = outputUIDs

        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * 0.030))
            eqProcessor?.updateSampleRate(deviceSampleRate)
            activeSampleRate = deviceSampleRate
        }

        installSampleRateListener(on: aggregateDeviceID)
    }

    private func cleanupPartialActivation() {
        if let procID = deviceProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }
        if aggregateDeviceID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
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
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
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
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in stride(from: 0, to: sampleCount, by: 2) {
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
        let crossfadeMultiplier: Float
        if _isCrossfading {
            crossfadeMultiplier = cos(_crossfadeProgress * .pi / 2.0)
        } else if _crossfadeProgress >= 1.0 {
            // Race condition guard: after crossfade completes, _isCrossfading is set false
            // but this callback may fire before the tap is destroyed. Keep silent to prevent pop.
            crossfadeMultiplier = 0.0
        } else {
            crossfadeMultiplier = 1.0
        }

        let inputBufferCount = inputBuffers.count
        let outputBufferCount = outputBuffers.count

        // Buffer routing: Some USB audio interfaces present as 4-in/2-out where
        // inputs 0-1 are microphone and inputs 2-3 are the process tap output.
        // We need to route the LAST N input buffers to the N output buffers,
        // skipping any leading input buffers (which are mic/line-in, not our tap).
        for outputIndex in 0..<outputBufferCount {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            // Calculate which input buffer maps to this output.
            // If we have more inputs than outputs, skip the first (inputCount - outputCount) inputs.
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
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            // Per-sample volume ramping prevents clicks. The exponential approach
            // (currentVol += (target - current) * coeff) gives smooth transitions.
            for i in 0..<sampleCount {
                currentVol += (targetVol - currentVol) * rampCoefficient
                // During crossfade, disable device volume compensation to avoid gain jumps
                let effectiveCompensation: Float = _isCrossfading ? 1.0 : _deviceVolumeCompensation
                var sample = inputSamples[i] * currentVol * crossfadeMultiplier * effectiveCompensation
                if targetVol > 1.0 {
                    sample = softLimit(sample)
                }
                outputSamples[i] = sample
            }

            if let eqProcessor = eqProcessor, !_isCrossfading {
                let channels = Int(inputBuffer.mNumberChannels)
                let frameCount = channels > 1 ? sampleCount / channels : sampleCount
                eqProcessor.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
            }
        }

        _primaryCurrentVolume = currentVol
    }

    /// Audio processing callback for SECONDARY tap during crossfade.
    private func processAudioSecondary(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        var maxPeak: Float = 0.0
        var totalSamplesThisBuffer: Int = 0
        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData else { continue }
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            if totalSamplesThisBuffer == 0 {
                totalSamplesThisBuffer = sampleCount / 2
            }
            for i in stride(from: 0, to: sampleCount, by: 2) {
                let absSample = abs(inputSamples[i])
                if absSample > maxPeak {
                    maxPeak = absSample
                }
            }
        }
        let rawPeak = min(maxPeak, 1.0)
        _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)

        _secondarySamplesProcessed += totalSamplesThisBuffer
        if _isCrossfading {
            _secondarySampleCount += Int64(totalSamplesThisBuffer)
        }

        if _isMuted {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        let targetVol = _volume
        var currentVol = _secondaryCurrentVolume

        var crossfadeMultiplier: Float = 1.0
        if _isCrossfading {
            let progress = min(1.0, Float(_secondarySampleCount) / Float(max(1, _crossfadeTotalSamples)))
            _crossfadeProgress = progress
            crossfadeMultiplier = sin(progress * .pi / 2.0)
        }

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
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<sampleCount {
                currentVol += (targetVol - currentVol) * secondaryRampCoefficient
                var sample = inputSamples[i] * currentVol * crossfadeMultiplier * _deviceVolumeCompensation
                if targetVol > 1.0 {
                    sample = softLimit(sample)
                }
                outputSamples[i] = sample
            }

            if let eqProcessor = eqProcessor, !_isCrossfading {
                let channels = Int(inputBuffer.mNumberChannels)
                let frameCount = channels > 1 ? sampleCount / channels : sampleCount
                eqProcessor.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
            }
        }

        _secondaryCurrentVolume = currentVol
    }

    /// Soft-knee limiter using asymptotic compression.
    /// Prevents clipping when volume > 100% (user boosting quiet audio).
    /// Below 0.8: pass through unchanged.
    /// Above 0.8: asymptotically approach 1.0 using hyperbolic curve.
    /// This preserves dynamics while preventing harsh digital clipping.
    @inline(__always)
    private func softLimit(_ sample: Float) -> Float {
        let threshold: Float = 0.8   // Start limiting at 80% of full scale
        let ceiling: Float = 1.0     // Never exceed 0dBFS

        let absSample = abs(sample)
        if absSample <= threshold {
            return sample  // Below threshold: no processing
        }

        // Hyperbolic compression: output = threshold + headroom * (x / (x + headroom))
        // As x → ∞, output → threshold + headroom = ceiling
        let overshoot = absSample - threshold
        let headroom = ceiling - threshold  // 0.2
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))

        return sample >= 0 ? compressed : -compressed
    }
}
