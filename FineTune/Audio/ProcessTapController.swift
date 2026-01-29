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
    private var targetDeviceUID: String
    private(set) var currentDeviceUID: String?

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

    init(app: AudioApp, targetDeviceUID: String, deviceMonitor: AudioDeviceMonitor? = nil) {
        self.app = app
        self.targetDeviceUID = targetDeviceUID
        self.deviceMonitor = deviceMonitor
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    // MARK: - Public Methods

    func updateEQSettings(_ settings: EQSettings) {
        eqProcessor?.updateSettings(settings)
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

        let outputUID = targetDeviceUID
        currentDeviceUID = outputUID

        // Create aggregate device combining the output device with our process tap.
        // The aggregate device's clock is the output device - important for USB DACs
        // which have their own clock and require the HAL to match their timing.
        // DriftCompensation=false on sub-device because it IS the clock source.
        // DriftCompensation=true on tap because the tapped process may use a different clock.
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

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

        activated = true
        logger.info("Tap activated for \(self.app.name)")
    }

    func switchDevice(to newDeviceUID: String) async throws {
        guard activated else {
            targetDeviceUID = newDeviceUID
            logger.debug("[SWITCH] Not activated, just updating target to \(newDeviceUID)")
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === START === \(self.app.name) -> \(newDeviceUID)")

        let newOutputUID = newDeviceUID

        do {
            try await performCrossfadeSwitch(to: newOutputUID)
        } catch {
            logger.warning("[SWITCH] Crossfade failed: \(error.localizedDescription), using fallback")
            guard tapDescription != nil else {
                throw CrossfadeError.noTapDescription
            }
            try await performDestructiveDeviceSwitch(to: newDeviceUID)
        }

        targetDeviceUID = newDeviceUID
        currentDeviceUID = newOutputUID

        let endTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === END === Total time: \((endTime - startTime) * 1000)ms")
    }

    /// Tears down the tap and releases all CoreAudio resources.
    /// Safe to call multiple times - subsequent calls are no-ops.
    func invalidate() {
        guard activated else { return }
        activated = false

        logger.debug("Invalidating tap for \(self.app.name)")

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

    // MARK: - Crossfade Operations

    private func performCrossfadeSwitch(to newOutputUID: String) async throws {
        logger.info("[CROSSFADE] Step 1: Reading device volumes for compensation")

        var isBluetoothDestination = false
        if let destDevice = deviceMonitor?.device(for: newOutputUID) {
            let transport = destDevice.id.readTransportType()
            isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
            logger.debug("[CROSSFADE] Destination device: BT=\(isBluetoothDestination)")
        }

        logger.info("[CROSSFADE] Step 2: Preparing crossfade state")

        _crossfadeProgress = 0
        _secondarySampleCount = 0
        _secondarySamplesProcessed = 0
        _isCrossfading = true

        logger.info("[CROSSFADE] Step 3: Creating secondary tap for new device")
        try createSecondaryTap(for: newOutputUID)

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

    private func createSecondaryTap(for outputUID: String) throws {
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

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)-secondary",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

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
        }

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

    private func performDestructiveDeviceSwitch(to newDeviceUID: String) async throws {
        let originalVolume = _volume

        _forceSilence = true
        logger.info("[SWITCH-DESTROY] Enabled _forceSilence=true")

        try await Task.sleep(for: .milliseconds(100))

        try performDeviceSwitch(to: newDeviceUID)

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

    private func performDeviceSwitch(to newDeviceUID: String) throws {
        let outputUID = newDeviceUID

        let newTapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        newTapDesc.uuid = UUID()
        newTapDesc.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(newTapDesc, &newTapID)
        guard err == noErr else {
            throw CrossfadeError.tapCreationFailed(err)
        }

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: newTapDesc.uuid.uuidString
                ]
            ]
        ]

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
        targetDeviceUID = newDeviceUID
        currentDeviceUID = outputUID

        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * 0.030))
            eqProcessor?.updateSampleRate(deviceSampleRate)
        }
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
