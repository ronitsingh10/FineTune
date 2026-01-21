// FineTune/Audio/ProcessTapController.swift
import AudioToolbox
import os

final class ProcessTapController {
    /// Configuration for crossfade behavior
    private enum CrossfadeConfig {
        static let defaultDuration: TimeInterval = 0.050  // 50ms

        static var duration: TimeInterval {
            let custom = UserDefaults.standard.double(forKey: "FineTuneCrossfadeDuration")
            return custom > 0 ? custom : defaultDuration
        }

        static func totalSamples(at sampleRate: Double) -> Int64 {
            Int64(sampleRate * duration)
        }
    }

    let app: AudioApp
    private let logger: Logger
    // Note: This queue is passed to AudioDeviceCreateIOProcIDWithBlock but the actual
    // audio callback runs on CoreAudio's real-time HAL I/O thread, not this queue.
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)

    /// Weak reference to device monitor for O(1) device lookups during crossfade
    private weak var deviceMonitor: AudioDeviceMonitor?

    // Lock-free volume access for real-time audio safety
    // Aligned Float32 reads/writes are atomic on Apple platforms.
    // Audio thread may read slightly stale volume values, which is acceptable
    // for volume control where exact synchronization isn't critical.
    private nonisolated(unsafe) var _volume: Float = 1.0

    // Separate volume states for primary and secondary taps (fixes race condition)
    // Each callback ramps independently toward _volume
    private nonisolated(unsafe) var _primaryCurrentVolume: Float = 1.0
    private nonisolated(unsafe) var _secondaryCurrentVolume: Float = 1.0

    // Force silence flag - when true, output zeros regardless of input
    // Used during device switching to prevent clicks/pops
    private nonisolated(unsafe) var _forceSilence: Bool = false

    // Mute flag - when true, output zeros (user-initiated mute)
    // Separate from _forceSilence which is for device switching
    private nonisolated(unsafe) var _isMuted: Bool = false

    // Device volume compensation scalar (applied during/after crossfade)
    // Computed as: sourceDeviceVolume / destinationDeviceVolume
    private nonisolated(unsafe) var _deviceVolumeCompensation: Float = 1.0

    // Peak audio level for VU meter display (0-1 range)
    // Written by audio callback, read by UI for visualization
    // Uses exponential smoothing to reduce nervous jumping
    private nonisolated(unsafe) var _peakLevel: Float = 0.0

    // Smoothing factor for VU meter (0-1)
    // Lower = smoother/slower response, Higher = more responsive
    // 0.3 gives ~30ms effective integration at 30fps UI update rate
    private let levelSmoothingFactor: Float = 0.3

    // Current device volume scalar (0-1) for VU meter calculation
    // Updated from main thread when device volume changes
    private nonisolated(unsafe) var _currentDeviceVolume: Float = 1.0

    // Current device mute state for VU meter calculation
    private nonisolated(unsafe) var _isDeviceMuted: Bool = false

    /// Current peak audio level (0-1) for VU meter visualization
    /// Read from main thread, written from audio callback (atomic Float)
    var audioLevel: Float { _peakLevel }

    /// Current device volume for VU meter scaling (atomic write from main thread)
    var currentDeviceVolume: Float {
        get { _currentDeviceVolume }
        set { _currentDeviceVolume = newValue }
    }

    /// Current device mute state for VU meter (atomic write from main thread)
    var isDeviceMuted: Bool {
        get { _isDeviceMuted }
        set { _isDeviceMuted = newValue }
    }

    // Ramp coefficient for ~30ms smoothing, computed from device sample rate on activation
    // Formula: 1 - exp(-1 / (sampleRate * rampTimeSeconds))
    private var rampCoefficient: Float = 0.0007  // Default, updated on activation
    private var secondaryRampCoefficient: Float = 0.0007  // For secondary tap during crossfade

    // EQ processor (pre-allocated at activation)
    private var eqProcessor: EQProcessor?

    var volume: Float {
        get { _volume }
        set { _volume = newValue }
    }

    var isMuted: Bool {
        get { _isMuted }
        set { _isMuted = newValue }
    }

    /// Update EQ settings (thread-safe, called from main thread)
    func updateEQSettings(_ settings: EQSettings) {
        eqProcessor?.updateSettings(settings)
    }

    // Target device UID (always explicit)
    private var targetDeviceUID: String
    private(set) var currentDeviceUID: String?

    // Core Audio state (primary tap)
    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var activated = false

    // Secondary tap for crossfade (only exists during device switch)
    private var secondaryTapID: AudioObjectID = .unknown
    private var secondaryAggregateID: AudioObjectID = .unknown
    private var secondaryDeviceProcID: AudioDeviceIOProcID?
    private var secondaryTapDescription: CATapDescription?

    // Crossfade state: 0 = full primary, 1 = full secondary
    private nonisolated(unsafe) var _crossfadeProgress: Float = 0
    private nonisolated(unsafe) var _isCrossfading: Bool = false

    // Sample-accurate crossfade timing (secondary callback drives progress)
    private nonisolated(unsafe) var _secondarySampleCount: Int64 = 0
    private nonisolated(unsafe) var _crossfadeTotalSamples: Int64 = 0

    // Warmup tracking: don't destroy primary until secondary has processed enough samples
    // Ensures secondary HAL I/O thread is fully connected before app unmutes
    private nonisolated(unsafe) var _secondarySamplesProcessed: Int = 0
    private let minimumWarmupSamples: Int = 2048  // ~43ms at 48kHz

    init(app: AudioApp, targetDeviceUID: String, deviceMonitor: AudioDeviceMonitor? = nil) {
        self.app = app
        self.targetDeviceUID = targetDeviceUID
        self.deviceMonitor = deviceMonitor
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    func activate() throws {
        guard !activated else { return }

        logger.debug("Activating tap for \(self.app.name)")

        // NOTE: CATapDescription stereoMixdownOfProcesses produces stereo Float32 interleaved.
        // The processAudio callback assumes this format.
        // Create process tap
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped  // Mute original, we provide the audio
        self.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        processTapID = tapID
        logger.debug("Created process tap #\(tapID)")

        // Use target device UID directly (always explicit)
        let outputUID = targetDeviceUID
        currentDeviceUID = outputUID

        // Create aggregate device
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
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

        logger.debug("Created aggregate device #\(self.aggregateDeviceID)")

        // Compute ramp coefficient from actual device sample rate
        let sampleRate: Float64
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
            logger.info("Device sample rate: \(sampleRate) Hz")
        } else {
            sampleRate = 48000
            logger.warning("Failed to read sample rate, using default: \(sampleRate) Hz")
        }
        let rampTimeSeconds: Float = 0.030  // 30ms smoothing
        rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))
        logger.debug("Ramp coefficient: \(self.rampCoefficient)")

        // Initialize EQ processor with device sample rate
        eqProcessor = EQProcessor(sampleRate: sampleRate)

        // Create IO proc with gain processing
        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        // Start the device
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        // Initialize current to target to skip initial fade-in
        _primaryCurrentVolume = _volume
        _deviceVolumeCompensation = 1.0  // No compensation on first activation

        // Only set activated after complete success
        activated = true
        logger.info("Tap activated for \(self.app.name)")
    }

    /// Switches the output device using dual-tap crossfade for seamless transition.
    /// Creates a second tap+aggregate for the new device, crossfades, then destroys the old one.
    func switchDevice(to newDeviceUID: String) async throws {
        guard activated else {
            targetDeviceUID = newDeviceUID
            logger.debug("[SWITCH] Not activated, just updating target to \(newDeviceUID)")
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === START === \(self.app.name) -> \(newDeviceUID)")

        // Use device UID directly (always explicit)
        let newOutputUID = newDeviceUID

        do {
            // Try crossfade approach
            try await performCrossfadeSwitch(to: newOutputUID)
        } catch {
            // Fall back to destroy/recreate if crossfade fails
            logger.warning("[SWITCH] Crossfade failed: \(error.localizedDescription), using fallback")
            guard let tapDesc = tapDescription else {
                throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No tap description available"])
            }
            try await performDestructiveDeviceSwitch(to: newDeviceUID, tapDesc: tapDesc)
        }

        targetDeviceUID = newDeviceUID
        currentDeviceUID = newOutputUID

        let endTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === END === Total time: \((endTime - startTime) * 1000)ms")
    }

    /// Performs a crossfade switch using two simultaneous taps.
    /// Secondary callback drives timing via sample counting for sample-accurate transitions.
    private func performCrossfadeSwitch(to newOutputUID: String) async throws {
        logger.info("[CROSSFADE] Step 1: Reading device volumes for compensation")

        // Read source device volume and sample rate
        // Fast path: use cached device lookup (O(1)), fallback to readDeviceList if cache miss
        var sourceVolume: Float = 1.0
        var sourceSampleRate: Float64 = 0
        if let sourceUID = currentDeviceUID {
            if let sourceDevice = deviceMonitor?.device(for: sourceUID) {
                // Cache hit - use O(1) lookup
                sourceVolume = sourceDevice.id.readOutputVolumeScalar()
                sourceSampleRate = (try? sourceDevice.id.readNominalSampleRate()) ?? 0
                logger.debug("[CROSSFADE] Source device (cached): volume=\(sourceVolume), sampleRate=\(sourceSampleRate)Hz")
            } else {
                // Fallback: device may have disconnected, try fresh read
                if let devices = try? AudioObjectID.readDeviceList(),
                   let sourceDevice = devices.first(where: { (try? $0.readDeviceUID()) == sourceUID }) {
                    sourceVolume = sourceDevice.readOutputVolumeScalar()
                    sourceSampleRate = (try? sourceDevice.readNominalSampleRate()) ?? 0
                    logger.debug("[CROSSFADE] Source device (fallback): volume=\(sourceVolume), sampleRate=\(sourceSampleRate)Hz")
                }
                // Continue with defaults if device gone
            }
        }

        // Read destination device volume and sample rate
        var destVolume: Float = 1.0
        var destSampleRate: Float64 = 0
        var isBluetoothDestination = false

        if let destDevice = deviceMonitor?.device(for: newOutputUID) {
            // Cache hit - use O(1) lookup
            destVolume = destDevice.id.readOutputVolumeScalar()
            destSampleRate = (try? destDevice.id.readNominalSampleRate()) ?? 0
            let transport = destDevice.id.readTransportType()
            isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
            logger.debug("[CROSSFADE] Destination device (cached): volume=\(destVolume), sampleRate=\(destSampleRate)Hz, BT=\(isBluetoothDestination)")
        } else {
            // Fallback: device may have disconnected, try fresh read
            if let devices = try? AudioObjectID.readDeviceList(),
               let destDevice = devices.first(where: { (try? $0.readDeviceUID()) == newOutputUID }) {
                destVolume = destDevice.readOutputVolumeScalar()
                destSampleRate = (try? destDevice.readNominalSampleRate()) ?? 0
                let transport = destDevice.readTransportType()
                isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
                logger.debug("[CROSSFADE] Destination device (fallback): volume=\(destVolume), sampleRate=\(destSampleRate)Hz, BT=\(isBluetoothDestination)")
            }
        }

        // Log sample rate mismatch but proceed with crossfade anyway
        // Crossfade is better than destructive switch because:
        // - Secondary tap is created BEFORE primary is destroyed
        // - No gap where audio leaks to system default output
        if sourceSampleRate > 0 && destSampleRate > 0 && sourceSampleRate != destSampleRate {
            logger.info("[CROSSFADE] Sample rate mismatch: source=\(sourceSampleRate)Hz, dest=\(destSampleRate)Hz - proceeding anyway (avoids audio leak)")
        }

        // Device volume compensation disabled - causes cumulative attenuation on round-trip switches
        // Keep compensation at 1.0 so slider directly controls output volume
        logger.info("[CROSSFADE] Device volumes: source=\(sourceVolume), dest=\(destVolume) (no compensation applied)")

        logger.info("[CROSSFADE] Step 2: Preparing crossfade state")

        // Enable crossfade BEFORE secondary tap starts, so it begins silent
        _crossfadeProgress = 0
        _secondarySampleCount = 0
        _secondarySamplesProcessed = 0  // Reset warmup counter for new secondary tap
        _isCrossfading = true

        // Create secondary tap (it will start at sin(0) = 0 = silent)
        logger.info("[CROSSFADE] Step 3: Creating secondary tap for new device")
        try createSecondaryTap(for: newOutputUID)

        if isBluetoothDestination {
            logger.info("[CROSSFADE] Destination is Bluetooth - using extended warmup")
        }

        // Wait for secondary tap to warm up and start producing samples
        // Bluetooth devices need much longer warmup due to connection latency
        let warmupMs = isBluetoothDestination ? 300 : 50
        logger.info("[CROSSFADE] Step 4: Waiting for secondary tap warmup (\(warmupMs)ms)...")
        try await Task.sleep(for: .milliseconds(UInt64(warmupMs)))

        logger.info("[CROSSFADE] Step 5: Crossfade in progress (\(CrossfadeConfig.duration * 1000)ms)")

        // Poll for completion (don't control timing - secondary callback does)
        // Wait for BOTH: crossfade animation complete AND secondary tap warmup complete
        // Bluetooth gets extended timeout to account for connection latency
        let timeoutMs = Int(CrossfadeConfig.duration * 1000) + (isBluetoothDestination ? 400 : 100)
        let pollIntervalMs: UInt64 = 5
        var elapsedMs: Int = 0

        while (_crossfadeProgress < 1.0 || _secondarySamplesProcessed < minimumWarmupSamples) && elapsedMs < timeoutMs {
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
            elapsedMs += Int(pollIntervalMs)
        }

        // Small buffer to ensure final samples processed
        try await Task.sleep(for: .milliseconds(10))

        // Crossfade complete - destroy primary, promote secondary
        logger.info("[CROSSFADE] Crossfade complete, promoting secondary")

        destroyPrimaryTap()
        promoteSecondaryToPrimary()

        // Set _isCrossfading = false AFTER promotion to avoid race condition:
        // Callback checks _isCrossfading, and if false, uses eqProcessor.
        // eqProcessor must already be the promoted one when this happens.
        _isCrossfading = false

        logger.info("[CROSSFADE] Complete")
    }

    /// Creates a secondary tap + aggregate for crossfade.
    private func createSecondaryTap(for outputUID: String) throws {
        // Create new process tap for the same app
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped  // Must mute to prevent audio on system default after primary destroyed
        secondaryTapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary tap: \(err)"])
        }
        secondaryTapID = tapID
        logger.debug("[CROSSFADE] Created secondary tap #\(tapID)")

        // Create aggregate device for new output
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)-secondary",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
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
            // Clean up tap
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryTapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary aggregate: \(err)"])
        }
        logger.debug("[CROSSFADE] Created secondary aggregate #\(self.secondaryAggregateID)")

        // Initialize sample-accurate crossfade timing from secondary device sample rate
        // Note: _secondarySampleCount is already set to 0 in performCrossfadeSwitch() before this is called
        let sampleRate: Double
        if let deviceSampleRate = try? secondaryAggregateID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
        } else {
            sampleRate = 48000
        }
        _crossfadeTotalSamples = CrossfadeConfig.totalSamples(at: sampleRate)

        // Compute ramp coefficient for secondary device's sample rate
        let rampTimeSeconds: Float = 0.030  // 30ms smoothing (same as primary)
        secondaryRampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))

        // Initialize secondary volume to match primary for smooth handoff
        _secondaryCurrentVolume = _primaryCurrentVolume

        // Create IO proc for secondary
        err = AudioDeviceCreateIOProcIDWithBlock(&secondaryDeviceProcID, secondaryAggregateID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            self.processAudioSecondary(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryAggregateID = .unknown
            secondaryTapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary IO proc: \(err)"])
        }

        // Start secondary device
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
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start secondary device: \(err)"])
        }

        logger.debug("[CROSSFADE] Secondary tap started")
    }

    /// Destroys the primary tap + aggregate.
    private func destroyPrimaryTap() {
        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let procID = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
        }

        deviceProcID = nil
        aggregateDeviceID = .unknown
        processTapID = .unknown
        tapDescription = nil
    }

    /// Promotes secondary tap to primary after crossfade.
    private func promoteSecondaryToPrimary() {
        processTapID = secondaryTapID
        aggregateDeviceID = secondaryAggregateID
        deviceProcID = secondaryDeviceProcID
        tapDescription = secondaryTapDescription

        // Update ramp coefficient for new device sample rate
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            let rampTimeSeconds: Float = 0.030
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * rampTimeSeconds))
        }

        // Update EQ processor sample rate to match new device
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            eqProcessor?.updateSampleRate(deviceSampleRate)
        }

        // Transfer volume state from secondary to primary (prevents volume jump)
        _primaryCurrentVolume = _secondaryCurrentVolume
        _secondaryCurrentVolume = 0

        // Reset crossfade state for next switch
        _crossfadeProgress = 0  // CRITICAL: Reset so new primary doesn't stay silent
        _secondarySampleCount = 0
        _crossfadeTotalSamples = 0

        // Clear secondary references
        secondaryTapID = .unknown
        secondaryAggregateID = .unknown
        secondaryDeviceProcID = nil
        secondaryTapDescription = nil
    }

    /// Fallback: Switches using destroy/recreate approach.
    private func performDestructiveDeviceSwitch(to newDeviceUID: String, tapDesc: CATapDescription) async throws {
        let originalVolume = _volume

        // Use device UID directly (always explicit)
        let newOutputUID = newDeviceUID

        var sourceVolume: Float = 1.0
        var destVolume: Float = 1.0

        // Fast path: use cached device lookup (O(1))
        var cachedSource: AudioDevice?
        var cachedDest: AudioDevice?

        if let sourceUID = currentDeviceUID {
            if let monitor = deviceMonitor {
                cachedSource = monitor.device(for: sourceUID)
                cachedDest = monitor.device(for: newOutputUID)
            }

            // Use cached values if available
            if let source = cachedSource {
                sourceVolume = source.id.readOutputVolumeScalar()
            }
            if let dest = cachedDest {
                destVolume = dest.id.readOutputVolumeScalar()
            }

            // Fallback for any missing device
            if cachedSource == nil || cachedDest == nil {
                if let devices = try? AudioObjectID.readDeviceList() {
                    if cachedSource == nil,
                       let source = devices.first(where: { (try? $0.readDeviceUID()) == sourceUID }) {
                        sourceVolume = source.readOutputVolumeScalar()
                    }
                    if cachedDest == nil,
                       let dest = devices.first(where: { (try? $0.readDeviceUID()) == newOutputUID }) {
                        destVolume = dest.readOutputVolumeScalar()
                    }
                }
            }
        }

        // Device volume compensation disabled - causes cumulative attenuation on round-trip switches
        logger.info("[SWITCH-DESTROY] Device volumes: source=\(sourceVolume), dest=\(destVolume) (no compensation applied)")

        _forceSilence = true
        logger.info("[SWITCH-DESTROY] Enabled _forceSilence=true")

        try await Task.sleep(for: .milliseconds(100))

        try performDeviceSwitch(to: newDeviceUID, tapDesc: tapDesc)

        _primaryCurrentVolume = 0
        _volume = 0

        try await Task.sleep(for: .milliseconds(150))

        _forceSilence = false

        // Gradual fade-in
        for i in 1...10 {
            _volume = originalVolume * Float(i) / 10.0
            try await Task.sleep(for: .milliseconds(20))
        }

        logger.info("[SWITCH-DESTROY] Complete")
    }

    /// Internal destroy/recreate switch (used as fallback).
    /// Creates new tap+aggregate BEFORE destroying old to prevent audio leak to system default.
    private func performDeviceSwitch(to newDeviceUID: String, tapDesc: CATapDescription) throws {
        // Use device UID directly (always explicit)
        let outputUID = newDeviceUID

        // STEP 1: Create NEW tap (process will be muted by BOTH old and new taps)
        let newTapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        newTapDesc.uuid = UUID()
        newTapDesc.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(newTapDesc, &newTapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create new tap: \(err)"])
        }

        // STEP 2: Create new aggregate with the new tap
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
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
            // Cleanup tap on failure
            AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate: \(err)"])
        }

        // STEP 3: Create and start IO proc for new aggregate
        var newDeviceProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newDeviceProcID, newAggregateID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        err = AudioDeviceStart(newAggregateID, newDeviceProcID)
        guard err == noErr else {
            if let procID = newDeviceProcID {
                AudioDeviceDestroyIOProcID(newAggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        // STEP 4: NOW destroy old tap + aggregate (process still muted by new tap)
        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let procID = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
        }

        // STEP 5: Promote new to primary
        processTapID = newTapID
        tapDescription = newTapDesc
        aggregateDeviceID = newAggregateID
        deviceProcID = newDeviceProcID
        targetDeviceUID = newDeviceUID
        currentDeviceUID = outputUID

        // Update ramp coefficient and EQ coefficients for new device sample rate
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * 0.030))
            eqProcessor?.updateSampleRate(deviceSampleRate)
        }
    }

    /// Audio processing callback for PRIMARY tap - runs on CoreAudio's real-time HAL I/O thread.
    ///
    /// **RT SAFETY CONSTRAINTS - DO NOT:**
    /// - Allocate memory (malloc, Array append, String operations)
    /// - Acquire locks/mutexes
    /// - Use Objective-C messaging
    /// - Call print/logging functions
    /// - Perform file/network I/O
    ///
    /// Current implementation is RT-safe: only atomic Float reads and simple math.
    /// See: https://developer.apple.com/library/archive/qa/qa1467/_index.html
    private func processAudio(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        // Check silence flag first (atomic Bool read)
        // When silencing for device switch, output zeros to prevent clicks
        if _forceSilence {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                // Zero the entire output buffer
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        // Track peak level for VU meter (RT-safe: simple max tracking + smoothing)
        // Always measure INPUT signal so VU shows source activity even when muted
        // This helps users see "app is playing" and supports future EQ visualization
        var maxPeak: Float = 0.0
        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData else { continue }
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            // Only check even samples (stereo interleaved: L, R, L, R...)
            for i in stride(from: 0, to: sampleCount, by: 2) {
                let absSample = abs(inputSamples[i])
                if absSample > maxPeak {
                    maxPeak = absSample
                }
            }
        }
        // Apply exponential smoothing to reduce nervous jumping
        // smoothed = previous + factor * (new - previous)
        let rawPeak = min(maxPeak, 1.0)
        _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)

        // Check user mute flag (atomic Bool read)
        // When muted, output zeros but VU meter still shows source activity (measured above)
        if _isMuted {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        // Read target once at start of buffer (atomic Float read)
        let targetVol = _volume
        var currentVol = _primaryCurrentVolume

        // During crossfade, primary tap fades OUT using equal-power curve
        // cos(0) = 1.0, cos(π/2) = 0.0
        // CRITICAL: Also stay silent when progress >= 1.0 even if _isCrossfading is false,
        // to prevent race condition pop between setting flag and destroying tap
        let crossfadeMultiplier: Float
        if _isCrossfading {
            crossfadeMultiplier = cos(_crossfadeProgress * .pi / 2.0)
        } else if _crossfadeProgress >= 1.0 {
            // Crossfade completed but tap not yet destroyed - stay silent
            crossfadeMultiplier = 0.0
        } else {
            crossfadeMultiplier = 1.0
        }

        // Copy input to output with ramped gain and soft limiting
        // IMPORTANT: When aggregate device has more input buffers than output buffers
        // (e.g., USB device with mic input + process tap), the tap audio is in the LAST input buffer.
        // We need to use the last input buffer, not the first, to get the tap audio.
        let inputBufferCount = inputBuffers.count
        let outputBufferCount = outputBuffers.count

        for outputIndex in 0..<outputBufferCount {
            // Use corresponding input buffer, but if there are more inputs than outputs,
            // use the LAST input buffer (which contains the tap audio)
            let inputIndex = inputBufferCount > outputBufferCount ? (inputBufferCount - outputBufferCount + outputIndex) : outputIndex
            guard inputIndex < inputBufferCount else { continue }

            let inputBuffer = inputBuffers[inputIndex]
            let outputBuffer = outputBuffers[outputIndex]

            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<sampleCount {
                // Per-sample volume ramping (one-pole lowpass)
                currentVol += (targetVol - currentVol) * rampCoefficient

                // Apply gain with crossfade multiplier
                // During crossfade, DON'T apply compensation to primary (it's on old device)
                // Compensation is only correct for the new device (secondary tap)
                let effectiveCompensation: Float = _isCrossfading ? 1.0 : _deviceVolumeCompensation
                var sample = inputSamples[i] * currentVol * crossfadeMultiplier * effectiveCompensation

                // Soft-knee limiter only when boosting (saves CPU at normal volumes)
                if targetVol > 1.0 {
                    sample = softLimit(sample)
                }

                outputSamples[i] = sample
            }

            // Apply EQ processing (after volume, before output)
            // Skip EQ during crossfade - 50ms flat EQ is imperceptible, avoids all EQ state glitches
            if let eqProcessor = eqProcessor, !_isCrossfading {
                let frameCount = sampleCount / 2  // Stereo frames
                eqProcessor.process(
                    input: outputSamples,
                    output: outputSamples,
                    frameCount: frameCount
                )
            }
        }

        // Store for next callback
        _primaryCurrentVolume = currentVol
    }

    /// Audio processing callback for SECONDARY tap.
    /// During crossfade: fades IN (0 → 1) while primary fades out.
    /// After promotion to primary: behaves identically to processAudio.
    /// OWNS crossfade timing via sample counting for sample-accurate transitions.
    private func processAudioSecondary(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        // Track peak level for VU meter (RT-safe: simple max tracking + smoothing)
        // Always measure INPUT signal so VU shows source activity even when muted
        var maxPeak: Float = 0.0
        var totalSamplesThisBuffer: Int = 0
        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData else { continue }
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            // Track samples for counter (only count once, not per channel)
            if totalSamplesThisBuffer == 0 {
                totalSamplesThisBuffer = sampleCount / 2  // Stereo interleaved: frames = samples / 2
            }
            // Only check even samples (stereo interleaved: L, R, L, R...)
            for i in stride(from: 0, to: sampleCount, by: 2) {
                let absSample = abs(inputSamples[i])
                if absSample > maxPeak {
                    maxPeak = absSample
                }
            }
        }
        // Apply exponential smoothing to reduce nervous jumping
        let rawPeak = min(maxPeak, 1.0)
        _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)

        // Always update counters (needed for crossfade timing even when muted)
        _secondarySamplesProcessed += totalSamplesThisBuffer
        if _isCrossfading {
            _secondarySampleCount += Int64(totalSamplesThisBuffer)
        }

        // Check user mute flag (atomic Bool read)
        // When muted, output zeros but VU meter still shows source activity (measured above)
        if _isMuted {
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        // Read target volume
        let targetVol = _volume
        var currentVol = _secondaryCurrentVolume

        // Compute crossfade multiplier and update progress (sample-accurate)
        var crossfadeMultiplier: Float = 1.0
        if _isCrossfading {
            // Update progress based on samples processed
            let progress = min(1.0, Float(_secondarySampleCount) / Float(max(1, _crossfadeTotalSamples)))
            _crossfadeProgress = progress
            // Equal-power fade IN: sin(0) = 0.0, sin(π/2) = 1.0
            crossfadeMultiplier = sin(progress * .pi / 2.0)
        }

        // Copy input to output with ramped gain and crossfade
        // IMPORTANT: When aggregate device has more input buffers than output buffers
        // (e.g., USB device with mic input + process tap), the tap audio is in the LAST input buffer.
        let inputBufferCount = inputBuffers.count
        let outputBufferCount = outputBuffers.count

        for outputIndex in 0..<outputBufferCount {
            // Use corresponding input buffer, but if there are more inputs than outputs,
            // use the LAST input buffer (which contains the tap audio)
            let inputIndex = inputBufferCount > outputBufferCount ? (inputBufferCount - outputBufferCount + outputIndex) : outputIndex
            guard inputIndex < inputBufferCount else { continue }

            let inputBuffer = inputBuffers[inputIndex]
            let outputBuffer = outputBuffers[outputIndex]

            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<sampleCount {
                // Per-sample volume ramping
                currentVol += (targetVol - currentVol) * secondaryRampCoefficient

                // Apply ramped gain with crossfade multiplier and device volume compensation
                var sample = inputSamples[i] * currentVol * crossfadeMultiplier * _deviceVolumeCompensation

                // Soft-knee limiter only when boosting (saves CPU at normal volumes)
                if targetVol > 1.0 {
                    sample = softLimit(sample)
                }

                outputSamples[i] = sample
            }

            // Apply EQ after crossfade completes (when this tap becomes the primary)
            // Skip during crossfade to prevent glitches from mixing EQ states
            if let eqProcessor = eqProcessor, !_isCrossfading {
                let frameCount = sampleCount / 2  // Stereo frames
                eqProcessor.process(
                    input: outputSamples,
                    output: outputSamples,
                    frameCount: frameCount
                )
            }
        }

        // Store for next callback
        _secondaryCurrentVolume = currentVol
    }

    /// Soft-knee limiter using asymptotic compression.
    /// Threshold at 0.8, smooth transition to ±1.0 ceiling.
    /// Output is guaranteed <= 1.0 for any finite input. Transparent for musical material.
    /// - Parameter sample: Input sample (may exceed ±1.0 when boosted)
    /// - Returns: Limited sample in range approximately ±1.0
    @inline(__always)
    private func softLimit(_ sample: Float) -> Float {
        let threshold: Float = 0.8
        let ceiling: Float = 1.0

        let absSample = abs(sample)
        if absSample <= threshold {
            return sample  // Below threshold: pass through
        }

        // Soft knee: smoothly compress above threshold
        let overshoot = absSample - threshold
        let headroom = ceiling - threshold  // 0.2
        // Asymptotic approach to ceiling
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))

        return sample >= 0 ? compressed : -compressed
    }

    /// Cleans up partially created CoreAudio resources on activation failure.
    /// Called when any step in activate() fails after resources were created.
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

    func invalidate() {
        guard activated else { return }
        activated = false

        logger.debug("Invalidating tap for \(self.app.name)")

        // Stop crossfade immediately if in progress
        _isCrossfading = false

        // Capture all IDs before clearing - teardown happens on background queue
        // to avoid blocking main thread (AudioDeviceDestroyIOProcID blocks until callback finishes)
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
            // Clean up secondary resources if they exist
            if secAggregate.isValid {
                AudioDeviceStop(secAggregate, secProcID)
                if let procID = secProcID {
                    AudioDeviceDestroyIOProcID(secAggregate, procID)
                }
                AudioHardwareDestroyAggregateDevice(secAggregate)
            }
            if secTap.isValid {
                AudioHardwareDestroyProcessTap(secTap)
            }

            // Clean up primary resources
            if primaryAggregate.isValid {
                AudioDeviceStop(primaryAggregate, primaryProcID)
                if let procID = primaryProcID {
                    AudioDeviceDestroyIOProcID(primaryAggregate, procID)
                }
                AudioHardwareDestroyAggregateDevice(primaryAggregate)
            }
            if primaryTap.isValid {
                AudioHardwareDestroyProcessTap(primaryTap)
            }
        }

        logger.info("Tap invalidated for \(self.app.name)")
    }

    deinit {
        invalidate()
    }
}
