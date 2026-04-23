// FineTune/Views/Rows/DeviceInspector/DeviceInspectorViewModel.swift
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Owns the CoreAudio property listeners backing the Device Inspector pane.
/// Constructed per-expanded-device; `start` registers listeners on main, `stop`
/// deregisters on teardown (tolerates `kAudioHardwareBadObjectError` when the
/// device disappears mid-session).
@MainActor
@Observable
final class DeviceInspectorViewModel {
    private(set) var info: DeviceInspectorInfo
    private(set) var hogModeOwnerName: String?
    var sampleRateError: String?

    private let deviceID: AudioDeviceID
    private let uid: String
    private let transportType: TransportType
    private var hogModeListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var errorClearTask: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune",
        category: "DeviceInspectorViewModel"
    )

    init(deviceID: AudioDeviceID, uid: String, transportType: TransportType) {
        self.deviceID = deviceID
        self.uid = uid
        self.transportType = transportType
        self.info = Self.snapshot(deviceID: deviceID, uid: uid, transportType: transportType)
        self.hogModeOwnerName = Self.resolveHogModeOwnerName(self.info.hogModeOwner)
    }

    // MARK: - Lifecycle

    func start() {
        refresh()
        registerHogModeListener()
        registerSampleRateListener()
    }

    func stop() {
        removeHogModeListener()
        removeSampleRateListener()
        errorClearTask?.cancel()
        errorClearTask = nil
    }

    // MARK: - User actions

    func selectSampleRate(_ rate: Double) {
        do {
            try deviceID.writeNominalSampleRate(rate)
            sampleRateError = nil
            // CoreAudio's listener can lag the write by several hundred ms;
            // refresh synchronously so the picker label flips immediately.
            refresh()
        } catch {
            Self.logger.debug("Sample rate write refused: \(String(describing: error))")
            sampleRateError = "Couldn't change sample rate. The device refused."
            scheduleErrorClear()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        info = Self.snapshot(deviceID: deviceID, uid: uid, transportType: transportType)
        hogModeOwnerName = Self.resolveHogModeOwnerName(info.hogModeOwner)
    }

    private static func snapshot(
        deviceID: AudioDeviceID,
        uid: String,
        transportType: TransportType
    ) -> DeviceInspectorInfo {
        let sampleRate = (try? deviceID.readNominalSampleRate()) ?? 0
        let available = deviceID.readAvailableSampleRates()
        let settable = deviceID.isPropertySettable(
            kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let asbd = deviceID.readPhysicalFormat()
        let hogOwner = deviceID.readHogModeOwner()

        return DeviceInspectorInfo(
            transportLabel: transportType.displayLabel,
            sampleRate: sampleRate,
            availableSampleRates: available,
            sampleRateSettable: settable,
            formatLabel: DeviceInspectorInfo.formatPhysicalFormat(asbd),
            hogModeOwner: hogOwner,
            uid: uid
        )
    }

    private static func resolveHogModeOwnerName(_ owner: pid_t) -> String? {
        guard owner > 0, owner != getpid() else { return nil }
        return ProcessNameLookup.name(for: owner)
    }

    // MARK: - Listener registration

    private func registerHogModeListener() {
        guard hogModeListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        if status == noErr {
            hogModeListener = block
        } else {
            Self.logger.warning("Failed to add hog-mode listener for device \(self.deviceID): \(status)")
        }
    }

    private func removeHogModeListener() {
        guard let block = hogModeListener else { return }
        hogModeListener = nil
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            Self.logger.warning("Failed to remove hog-mode listener for device \(self.deviceID): \(status)")
        }
    }

    private func registerSampleRateListener() {
        guard sampleRateListener == nil else { return }
        // Global scope: NominalSampleRate is device-wide; output-scope listeners
        // don't receive notifications on most drivers.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        if status == noErr {
            sampleRateListener = block
        } else {
            Self.logger.warning("Failed to add sample-rate listener for device \(self.deviceID): \(status)")
        }
    }

    private func removeSampleRateListener() {
        guard let block = sampleRateListener else { return }
        sampleRateListener = nil
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            Self.logger.warning("Failed to remove sample-rate listener for device \(self.deviceID): \(status)")
        }
    }

    // MARK: - Error banner auto-dismiss

    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.sampleRateError = nil
        }
    }
}

// MARK: - TransportType human label

extension TransportType {
    /// Capitalized label used in the inspector info grid. Distinct from the
    /// lowercased `description` which is used in the existing header row.
    var displayLabel: String {
        switch self {
        case .builtIn:     return "Built-in"
        case .usb:         return "USB"
        case .bluetooth:   return "Bluetooth"
        case .bluetoothLE: return "Bluetooth LE"
        case .airPlay:     return "AirPlay"
        case .hdmi:        return "HDMI"
        case .virtual:     return "Virtual"
        default:           return "Other"
        }
    }
}
