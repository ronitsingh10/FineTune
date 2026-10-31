// FineTune/Audio/Engine/CallDuckingGuard.swift
import CoreAudio
import Darwin
import os

/// Keeps FineTune's output at full volume while a call app ducks "other audio".
///
/// When a voice-processing client (FaceTime's `avconferenced`, WhatsApp, …) starts a
/// call, coreaudiod ducks every other HAL client on the output device to a combined
/// volume scalar of 0.178 (-15 dB). FineTune renders every tapped app through its own
/// HAL client, so the whole mixer drops to ~18% for the length of the call — and so does
/// the call itself whenever FineTune taps it (#67, #113, #156, #241, #262, #360, #426).
///
/// coreaudiod never ducks a client that holds a duck request of its own: its log calls
/// such clients "duckers" and gives them a scalar of 1.0 no matter what anybody else
/// requests. This guard holds a request of 0.999 (-0.01 dB, inaudible) on every output
/// device, which exempts FineTune's replay while leaving the call's ducking of audio that
/// bypasses FineTune (ignored apps, system sounds) exactly as macOS intends.
///
/// The request belongs to the process ↔ device pair, not to an IO proc: it can be made
/// before any aggregate exists and it survives tearing the private aggregates down and
/// recreating them (checked on macOS 26.6 against `_UpdateClientVolumeScalarDucking` in
/// coreaudiod's log). A level of exactly 1.0 withdraws the request again.
///
/// `AudioDeviceDuck` is exported by CoreAudio but absent from its public headers (WebKit
/// and Chromium call it the same way). It is resolved with `dlsym`, so a macOS release
/// that drops it degrades to "calls duck FineTune as before" instead of a failed launch.
@MainActor
final class CallDuckingGuard {
    /// `(deviceID, level) -> OSStatus`. Tests inject a recorder; production wraps `AudioDeviceDuck`.
    typealias DuckFunction = @Sendable (AudioDeviceID, Float32) -> OSStatus

    /// Below 1.0 so coreaudiod keeps the request on file, close enough to unity that the
    /// -0.01 dB it imposes on clients outside FineTune is inaudible.
    static let holdLevel: Float32 = 0.999
    /// Exactly 1.0 makes coreaudiod drop this client's request ("unducking" in its log).
    static let releaseLevel: Float32 = 1.0

    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "CallDuckingGuard")
    private let duck: DuckFunction?

    /// Devices that currently carry FineTune's request.
    private(set) var heldDeviceIDs: Set<AudioDeviceID> = []
    /// Devices whose last request failed. Logged once; retried on the next `hold`.
    private var failedDeviceIDs: Set<AudioDeviceID> = []

    private(set) var isEnabled: Bool

    init(isEnabled: Bool, duckFunction: DuckFunction? = CallDuckingGuard.systemDuckFunction) {
        self.isEnabled = isEnabled
        self.duck = duckFunction
    }

    /// False when the private symbol could not be resolved on this macOS.
    var isAvailable: Bool { duck != nil }

    /// Turning the guard off withdraws every request at once, so a running call's ducking
    /// applies to FineTune again. Turning it on holds nothing by itself: the caller passes
    /// the current output devices to `hold` next.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled {
            releaseAll()
        }
    }

    /// Holds a request on `deviceID`. No-op when disabled, unavailable, or already held.
    func hold(_ deviceID: AudioDeviceID) {
        guard isEnabled, let duck, deviceID.isValid, !heldDeviceIDs.contains(deviceID) else { return }

        let status = duck(deviceID, Self.holdLevel)
        if status == noErr {
            heldDeviceIDs.insert(deviceID)
            failedDeviceIDs.remove(deviceID)
            logger.info("Holding ducking exemption on output device \(deviceID)")
        } else if failedDeviceIDs.insert(deviceID).inserted {
            logger.warning("AudioDeviceDuck(\(deviceID), \(Self.holdLevel)) failed: OSStatus \(status)")
        }
    }

    func hold(_ deviceIDs: some Sequence<AudioDeviceID>) {
        for deviceID in deviceIDs {
            hold(deviceID)
        }
    }

    /// Withdraws the request on `deviceID`. No-op when nothing is held there.
    func release(_ deviceID: AudioDeviceID) {
        guard heldDeviceIDs.remove(deviceID) != nil, let duck else { return }

        let status = duck(deviceID, Self.releaseLevel)
        if status == noErr {
            logger.info("Released ducking exemption on output device \(deviceID)")
        } else {
            // The device may already be gone; coreaudiod drops the request with it.
            logger.debug("AudioDeviceDuck(\(deviceID), \(Self.releaseLevel)) failed: OSStatus \(status)")
        }
    }

    func releaseAll() {
        for deviceID in heldDeviceIDs {
            release(deviceID)
        }
    }

    /// Forgets devices that are no longer connected. coreaudiod discards a request together
    /// with its device, and a reconnected device comes back under a new ID anyway.
    func retain(only connectedDeviceIDs: Set<AudioDeviceID>) {
        heldDeviceIDs.formIntersection(connectedDeviceIDs)
        failedDeviceIDs.formIntersection(connectedDeviceIDs)
    }

    // MARK: - Private symbol

    private typealias AudioDeviceDuckFunction = @convention(c) (
        AudioDeviceID, Float32, UnsafePointer<AudioTimeStamp>?, Float32
    ) -> OSStatus

    /// Resolved once per process. RTLD_DEFAULT (-2) searches every loaded image, CoreAudio included.
    /// The nil start time and zero ramp apply the level immediately, as WebKit does.
    nonisolated static let systemDuckFunction: DuckFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else {
            return nil
        }
        let audioDeviceDuck = unsafeBitCast(symbol, to: AudioDeviceDuckFunction.self)
        return { deviceID, level in audioDeviceDuck(deviceID, level, nil, 0) }
    }()
}
