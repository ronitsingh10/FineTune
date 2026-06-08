// FineTune/Audio/Permission/AudioRecordingPermission.swift
import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "Permission")

// MARK: - Permission Status

enum AudioCapturePermissionStatus {
    case unknown
    case authorized
    case denied
}

// MARK: - AudioRecordingPermission

@Observable
@MainActor
final class AudioRecordingPermission {

    var status: AudioCapturePermissionStatus = .unknown

    init() {
        refreshStatus()
        registerForActivation()
    }

    /// Check current TCC status without prompting.
    func refreshStatus() {
        #if ENABLE_TCC_SPI
        let result = Self.preflight()
        switch result {
        case 0:
            status = .authorized
        case 1:
            status = .denied
        default:
            status = .unknown
        }
        logger.debug("Audio capture permission preflight: \(result) → \(String(describing: self.status))")
        #else
        status = .authorized
        #endif
    }

    /// Trigger the system permission dialog. Only shows once per app per TCC service.
    /// Subsequent calls are no-ops at the OS level.
    func request() {
        #if ENABLE_TCC_SPI
        guard status != .authorized else { return }
        Self.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.status = granted ? .authorized : .denied
                logger.info("Audio capture permission request result: \(granted)")
            }
        }
        #endif
    }

    // MARK: - App Activation Observer

    private func registerForActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }
    }

    // MARK: - TCC SPI (Private Framework)

    #if ENABLE_TCC_SPI
    private static let tccServiceAudioCapture = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFunc? = {
        guard let handle = apiHandle,
              let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFunc.self)
    }()

    private static let requestSPI: RequestFunc? = {
        guard let handle = apiHandle,
              let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFunc.self)
    }()

    /// Returns: 0 = authorized, 1 = denied, -1 = SPI unavailable
    private static func preflight() -> Int {
        guard let spi = preflightSPI else {
            logger.warning("TCC preflight SPI unavailable")
            return -1
        }
        return spi(tccServiceAudioCapture, nil)
    }

    private static func requestAccess(completion: @escaping (Bool) -> Void) {
        guard let spi = requestSPI else {
            logger.warning("TCC request SPI unavailable")
            completion(false)
            return
        }
        spi(tccServiceAudioCapture, nil, completion)
    }
    #endif
}
