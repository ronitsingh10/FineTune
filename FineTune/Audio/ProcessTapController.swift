// FineTune/Audio/ProcessTapController.swift
import AudioToolbox
import os

final class ProcessTapController {
    let app: AudioApp
    private let logger: Logger
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)

    // Lock-free volume access for real-time audio safety
    // Aligned Float32 reads/writes are atomic on Apple platforms.
    // Audio thread may read slightly stale volume values, which is acceptable
    // for volume control where exact synchronization isn't critical.
    private nonisolated(unsafe) var _volume: Float = 1.0

    // Current interpolated volume (audio thread only, ramps toward _volume)
    private nonisolated(unsafe) var _currentVolume: Float = 1.0

    // Ramp coefficient for ~30ms smoothing at 48kHz
    // Formula: 1 - exp(-1 / (sampleRate * rampTimeSeconds))
    // Conservative value works across 44.1kHz-96kHz sample rates
    private let rampCoefficient: Float = 0.0007

    var volume: Float {
        get { _volume }
        set { _volume = newValue }
    }

    // Core Audio state
    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var activated = false

    init(app: AudioApp) {
        self.app = app
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    func activate() throws {
        guard !activated else { return }

        logger.debug("Activating tap for \(self.app.name)")

        // NOTE: CATapDescription stereoMixdownOfProcesses produces stereo Float32 interleaved.
        // The processAudio callback assumes this format.
        // Create process tap
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped  // Mute original, we provide the audio

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        processTapID = tapID
        logger.debug("Created process tap #\(tapID)")

        // Get system output device
        let systemOutputID: AudioDeviceID
        let outputUID: String
        do {
            systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
            outputUID = try systemOutputID.readDeviceUID()
        } catch {
            cleanupPartialActivation()
            throw error
        }

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
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
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
        _currentVolume = _volume

        // Only set activated after complete success
        activated = true
        logger.info("Tap activated for \(self.app.name)")
    }

    private func processAudio(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        // Read target once at start of buffer (atomic Float read)
        let targetVol = _volume
        var currentVol = _currentVolume

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)

        // Copy input to output with ramped gain and soft limiting
        for (inputBuffer, outputBuffer) in zip(inputBuffers, outputBuffers) {
            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<sampleCount {
                // Per-sample volume ramping (one-pole lowpass)
                currentVol += (targetVol - currentVol) * rampCoefficient

                // Apply gain
                var sample = inputSamples[i] * currentVol

                // Soft-knee limiter (prevents harsh clipping when boosting)
                sample = softLimit(sample)

                outputSamples[i] = sample
            }
        }

        // Store for next callback
        _currentVolume = currentVol
    }

    /// Soft-knee limiter using asymptotic compression
    /// Threshold at 0.8, smooth transition to ±1.0 ceiling
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
        defer { activated = false }

        logger.debug("Invalidating tap for \(self.app.name)")

        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { logger.warning("Failed to stop device: \(err)") }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { logger.warning("Failed to destroy IO proc: \(err)") }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr { logger.warning("Failed to destroy aggregate device: \(err)") }
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr { logger.warning("Failed to destroy process tap: \(err)") }
            processTapID = .unknown
        }

        logger.info("Tap invalidated for \(self.app.name)")
    }

    deinit {
        invalidate()
    }
}
