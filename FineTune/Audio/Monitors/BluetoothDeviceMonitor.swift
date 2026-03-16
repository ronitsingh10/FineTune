// FineTune/Audio/Monitors/BluetoothDeviceMonitor.swift
import AppKit
import IOBluetooth
import os

/// Discovers paired-but-disconnected Bluetooth audio devices and initiates connections.
/// All IOBluetooth interaction is isolated here — no other file imports IOBluetooth.
///
/// All IOBluetooth calls are dispatched to a dedicated serial queue (`btQueue`) to
/// serialize Mach port IPC and avoid the cooperative thread pool used by Task.detached.
@Observable
@MainActor
final class BluetoothDeviceMonitor {

    // MARK: - Published State

    /// Whether the Bluetooth hardware is powered on.
    private(set) var isBluetoothOn: Bool = false

    /// Paired-but-disconnected audio BT devices, sorted by name.
    private(set) var pairedDevices: [PairedBluetoothDevice] = []

    /// MAC addresses currently in-flight (spinner shown).
    private(set) var connectingIDs: Set<String> = []

    /// Inline error messages keyed by MAC address.
    private(set) var connectionErrors: [String: String] = [:]

    // MARK: - Private

    private let logger = Logger(
        subsystem: "com.finetuneapp.FineTune",
        category: "BluetoothDeviceMonitor"
    )

    /// Dedicated serial queue for all IOBluetooth IPC.
    /// Serializes calls to avoid concurrent Mach port access and provides a stable
    /// thread context (unlike Task.detached which uses the cooperative thread pool).
    private static let btQueue = DispatchQueue(label: "com.finetuneapp.bluetooth")

    /// Pending timeout tasks keyed by MAC address.
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Error auto-clear tasks keyed by MAC address.
    private var errorClearTasks: [String: Task<Void, Never>] = [:]

    /// In-flight refresh task — cancelled on each new refresh to avoid stacking.
    private var refreshTask: Task<Void, Never>?

    private let connectTimeoutSeconds: Double = 12

    // MARK: - A2DP / HFP SDP UUIDs

    private static let a2dpSinkUUID = IOBluetoothSDPUUID(uuid16: 0x110B)!
    private static let hfpUUID = IOBluetoothSDPUUID(uuid16: 0x111E)!

    /// Observers for Bluetooth power state change notifications.
    /// nonisolated(unsafe) so deinit can remove them.
    private nonisolated(unsafe) var powerOnObserver: NSObjectProtocol?
    private nonisolated(unsafe) var powerOffObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    deinit {
        if let powerOnObserver { NotificationCenter.default.removeObserver(powerOnObserver) }
        if let powerOffObserver { NotificationCenter.default.removeObserver(powerOffObserver) }
    }

    func start() {
        powerOnObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("IOBluetoothHostControllerPoweredOnNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        powerOffObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("IOBluetoothHostControllerPoweredOffNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        refresh()
    }

    // MARK: - Refresh

    /// Rebuilds `pairedDevices` from the current IOBluetooth snapshot.
    /// Call on popup-appear and after any CoreAudio device list change.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let powered = await Self.runOnBTQueue {
                IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
            }
            guard !Task.isCancelled else { return }

            isBluetoothOn = powered

            guard powered else {
                pairedDevices = []
                return
            }

            let connectingSnapshot = connectingIDs
            let rawDevices = await Self.runOnBTQueue {
                Self.fetchPairedAudioDevices(excludingConnectingIDs: connectingSnapshot)
            }
            guard !Task.isCancelled else { return }

            let devices = rawDevices.map { raw in
                PairedBluetoothDevice(
                    id: raw.mac,
                    name: raw.name,
                    icon: NSImage(
                        systemSymbolName: raw.iconName,
                        accessibilityDescription: raw.name
                    )
                )
            }
            pairedDevices = devices
            logger.debug("Paired BT audio devices: \(devices.count)")
        }
    }

    // MARK: - Connect

    /// Initiates a Bluetooth connection for the given paired device.
    func connect(device: PairedBluetoothDevice) {
        let mac = device.id
        guard !connectingIDs.contains(mac) else { return }

        logger.info("Connecting to \(device.name) (\(mac))")

        connectingIDs.insert(mac)
        connectionErrors.removeValue(forKey: mac)

        Task {
            let result = await Self.runOnBTQueue {
                guard let btDevice = IOBluetoothDevice(addressString: mac) else {
                    return kIOReturnNotFound
                }
                return btDevice.openConnection()
            }

            if result != kIOReturnSuccess {
                logger.error("\(device.name): openConnection failed (IOReturn \(result))")
                finishConnecting(mac: mac, error: "Couldn't connect")
                return
            }

            // openConnection() is asynchronous — success detected when the device
            // appears in CoreAudio and notifyDeviceAppearedInCoreAudio() is called.
            startConnectTimeout(mac: mac, name: device.name)
        }
    }

    /// Called when a new CoreAudio output device appears.
    /// Always refreshes the paired list so auto-connected devices (not initiated
    /// via FineTune) are removed. If a FineTune-initiated connection is in flight,
    /// clears the connecting state for devices that succeeded.
    func notifyDeviceAppearedInCoreAudio() {
        if !connectingIDs.isEmpty {
            Task {
                let stillDisconnected = await Self.runOnBTQueue {
                    let allPaired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
                    return Set(allPaired.filter { !$0.isConnected() }.compactMap { $0.addressString })
                }

                // Clear connecting state for devices that actually connected
                for mac in connectingIDs {
                    if !stillDisconnected.contains(mac) {
                        logger.debug("Device \(mac) connected; clearing in-flight state")
                        timeoutTasks[mac]?.cancel()
                        timeoutTasks.removeValue(forKey: mac)
                        connectingIDs.remove(mac)
                        pairedDevices.removeAll { $0.id == mac }
                    }
                }

                refresh()
            }
        } else {
            // Auto-connected device (not via FineTune) — still need to refresh
            // so the device is removed from the paired list.
            refresh()
        }
    }

    // MARK: - IOBluetooth Queue Helper

    /// Runs a closure on the dedicated Bluetooth serial queue and returns the result.
    /// Bridges DispatchQueue → Swift concurrency via `withCheckedContinuation`.
    private nonisolated static func runOnBTQueue<T: Sendable>(
        _ work: @Sendable @escaping () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            btQueue.async {
                autoreleasepool {
                    continuation.resume(returning: work())
                }
            }
        }
    }

    // MARK: - Background IOBluetooth Work

    /// Sendable snapshot of a paired device — transfers safely across actor boundaries.
    private struct RawPairedDevice: Sendable {
        let mac: String
        let name: String
        let iconName: String
    }

    /// Runs on btQueue. Returns filtered, sorted paired audio devices.
    private nonisolated static func fetchPairedAudioDevices(
        excludingConnectingIDs connectingIDs: Set<String>
    ) -> [RawPairedDevice] {
        guard let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        var result: [RawPairedDevice] = []

        for device in all {
            guard !device.isConnected() else { continue }

            let mac = device.addressString ?? ""
            guard !mac.isEmpty else { continue }
            guard !connectingIDs.contains(mac) else { continue }

            let hasA2DP = device.getServiceRecord(for: a2dpSinkUUID) != nil
            let hasHFP = device.getServiceRecord(for: hfpUUID) != nil
            guard hasA2DP || hasHFP else { continue }

            let name = device.name ?? mac
            result.append(RawPairedDevice(mac: mac, name: name, iconName: suggestedIconName(for: name)))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// Pure function — safe to call from any thread.
    private nonisolated static func suggestedIconName(for name: String) -> String {
        if name.contains("AirPods Pro") { return "airpodspro" }
        if name.contains("AirPods Max") { return "airpodsmax" }
        if name.contains("AirPods") { return "airpods.gen3" }
        if name.contains("HomePod mini") { return "homepodmini" }
        if name.contains("HomePod") { return "homepod" }
        if name.contains("Beats") { return "beats.headphones" }
        return "headphones"
    }

    // MARK: - Private Helpers

    private func startConnectTimeout(mac: String, name: String) {
        timeoutTasks[mac]?.cancel()
        timeoutTasks[mac] = Task { [weak self, connectTimeoutSeconds] in
            try? await Task.sleep(for: .seconds(connectTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.logger.warning("\(name) connect timeout after \(connectTimeoutSeconds)s")
            self?.finishConnecting(mac: mac, error: "Connection timed out")
        }
    }

    private func finishConnecting(mac: String, error: String?) {
        timeoutTasks[mac]?.cancel()
        timeoutTasks.removeValue(forKey: mac)
        connectingIDs.remove(mac)

        if let error {
            connectionErrors[mac] = error
            scheduleErrorClear(mac: mac)
        }

        refresh()
    }

    private func scheduleErrorClear(mac: String) {
        errorClearTasks[mac]?.cancel()
        errorClearTasks[mac] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.connectionErrors.removeValue(forKey: mac)
        }
    }

}
