// FineTune/Audio/TapResources.swift
import AudioToolbox
import os

/// Encapsulates Core Audio tap and aggregate device resources.
/// Provides safe cleanup with correct teardown order.
///
/// **Teardown order is critical:**
/// 1. Stop device proc (AudioDeviceStop)
/// 2. Destroy IO proc ID (AudioDeviceDestroyIOProcID) — blocks until callback finishes
/// 3. Destroy aggregate device (AudioHardwareDestroyAggregateDevice)
/// 4. Destroy process tap (AudioHardwareDestroyProcessTap)
///
/// Violating this order can leak HAL resources or crash on shutdown.
struct TapResources {
    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "TapResources")

    var tapID: AudioObjectID = .unknown
    var aggregateDeviceID: AudioObjectID = .unknown
    var deviceProcID: AudioDeviceIOProcID?
    var tapDescription: CATapDescription?

    /// Whether these resources are currently active
    var isActive: Bool {
        tapID.isValid || aggregateDeviceID.isValid
    }

    /// Destroys all resources in the correct order to prevent leaks and crashes.
    /// Safe to call multiple times — invalid IDs are skipped.
    mutating func destroy() {
        // Capture IDs before mutation (os.Logger autoclosure can't capture mutating self)
        let aggID = aggregateDeviceID
        let tID = tapID

        // Step 1 & 2: Stop and destroy IO proc
        if aggID.isValid {
            if let procID = deviceProcID {
                let stopErr = AudioDeviceStop(aggID, procID)
                if stopErr != noErr {
                    Self.logger.error("AudioDeviceStop failed for aggregate \(aggID): OSStatus \(stopErr)")
                }
                let destroyProcErr = AudioDeviceDestroyIOProcID(aggID, procID)
                if destroyProcErr != noErr {
                    Self.logger.error("AudioDeviceDestroyIOProcID failed for aggregate \(aggID): OSStatus \(destroyProcErr)")
                }
            }
        }
        deviceProcID = nil

        // Step 3: Destroy aggregate device
        if aggID.isValid {
            CrashGuard.untrackDevice(aggID)
            let aggErr = AudioHardwareDestroyAggregateDevice(aggID)
            if aggErr != noErr {
                Self.logger.error("AudioHardwareDestroyAggregateDevice failed for \(aggID): OSStatus \(aggErr)")
            }
        }
        aggregateDeviceID = .unknown

        // Step 4: Destroy process tap
        if tID.isValid {
            let tapErr = AudioHardwareDestroyProcessTap(tID)
            if tapErr != noErr {
                Self.logger.error("AudioHardwareDestroyProcessTap failed for \(tID): OSStatus \(tapErr)")
            }
        }
        tapID = .unknown

        tapDescription = nil
    }

    /// Destroys resources asynchronously on a background queue.
    /// Clears instance state immediately so new resources can be created without waiting.
    ///
    /// Use this when destruction might block (e.g., AudioDeviceDestroyIOProcID
    /// blocks until the current IO cycle completes).
    ///
    /// - Parameters:
    ///   - queue: Queue to perform destruction on (default: global utility)
    ///   - completion: Optional callback invoked after all resources are destroyed
    mutating func destroyAsync(on queue: DispatchQueue = .global(qos: .utility), completion: (() -> Void)? = nil) {
        // Capture values before clearing
        let capturedTapID = tapID
        let capturedAggregateID = aggregateDeviceID
        let capturedProcID = deviceProcID

        // Clear instance state immediately
        tapID = .unknown
        aggregateDeviceID = .unknown
        deviceProcID = nil
        tapDescription = nil

        // Dispatch blocking teardown to background
        queue.async {
            // Step 1 & 2: Stop and destroy IO proc
            if capturedAggregateID.isValid, let procID = capturedProcID {
                let stopErr = AudioDeviceStop(capturedAggregateID, procID)
                if stopErr != noErr {
                    Self.logger.error("AudioDeviceStop failed for aggregate \(capturedAggregateID): OSStatus \(stopErr)")
                }
                let destroyProcErr = AudioDeviceDestroyIOProcID(capturedAggregateID, procID)
                if destroyProcErr != noErr {
                    Self.logger.error("AudioDeviceDestroyIOProcID failed for aggregate \(capturedAggregateID): OSStatus \(destroyProcErr)")
                }
            }

            // Step 3: Destroy aggregate device
            if capturedAggregateID.isValid {
                CrashGuard.untrackDevice(capturedAggregateID)
                let aggErr = AudioHardwareDestroyAggregateDevice(capturedAggregateID)
                if aggErr != noErr {
                    Self.logger.error("AudioHardwareDestroyAggregateDevice failed for \(capturedAggregateID): OSStatus \(aggErr)")
                }
            }

            // Step 4: Destroy process tap
            if capturedTapID.isValid {
                let tapErr = AudioHardwareDestroyProcessTap(capturedTapID)
                if tapErr != noErr {
                    Self.logger.error("AudioHardwareDestroyProcessTap failed for \(capturedTapID): OSStatus \(tapErr)")
                }
            }

            completion?()
        }
    }
}
