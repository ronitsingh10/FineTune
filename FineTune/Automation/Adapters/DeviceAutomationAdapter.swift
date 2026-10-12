import AppKit
import AudioToolbox
import Foundation

@MainActor
final class DeviceAutomationAdapter: AutomationAdapter {
    let stateKey = "devices"
    let engine: AudioEngine
    init(engine: AudioEngine) { self.engine = engine }
    var descriptors: [AutomationDescriptor] {
        let t = AutomationField(name: "target", type: "target", source: "devices")
        let percent = AutomationField(name: "percent", type: "number", minimum: 0, maximum: 100)
        return [
            .init(method: "device.list", title: "List Devices", fields: []),
            .init(method: "device.get", title: "Device State", fields: [t]),
            .init(method: "device.volume.set", title: "Set Device Volume", fields: [t, percent]),
            .init(
                method: "device.volume.step", title: "Step Device Volume",
                fields: [t, .init(name: "delta", type: "number", minimum: -100, maximum: 100)],
                dialParameter: "delta", units: "%"),
            .init(
                method: "device.mute.set", title: "Set Device Mute",
                fields: [t, .init(name: "muted", type: "boolean")]),
            .init(method: "device.mute.toggle", title: "Toggle Device Mute", fields: [t]),
            .init(method: "device.default.set", title: "Select Default Device", fields: [t]),
            .init(
                method: "device.hidden.set", title: "Hide Device",
                fields: [t, .init(name: "hidden", type: "boolean")]),
            .init(
                method: "device.priority.set", title: "Set Device Priority",
                fields: [
                    .init(name: "direction", type: "string", choices: ["input", "output"]),
                    .init(name: "deviceUIDs", type: "strings", source: "devices", ordered: true),
                ]),
            .init(
                method: "device.icon.set", title: "Set Device Icon",
                fields: [t, .init(name: "symbol", type: "string")]),
            .init(method: "device.icon.clear", title: "Reset Device Icon", fields: [t]),
            .init(
                method: "device.volumeBackend.set", title: "Select Volume Backend",
                fields: [t, .init(name: "backend", type: "string", choices: ["auto", "software"])]),
            .init(
                method: "device.sampleRate.set", title: "Set Sample Rate",
                fields: [t, .init(name: "sampleRate", type: "number", minimum: 8000, maximum: 768000)]),
            .init(
                method: "input.lock.set", title: "Set Input Lock",
                fields: [
                    .init(name: "enabled", type: "boolean"),
                    .init(name: "deviceUID", type: "string", required: false, source: "inputs"),
                ]),
            .init(method: "alert.volume.set", title: "Set Alert Volume", fields: [percent]),
            .init(
                method: "alert.volume.step", title: "Step Alert Volume",
                fields: [.init(name: "delta", type: "number", minimum: -100, maximum: 100)],
                dialParameter: "delta", units: "%"),
            .init(
                method: "alert.routing.set", title: "Route Alert Audio",
                fields: [
                    .init(name: "followDefault", type: "boolean"),
                    .init(name: "deviceUID", type: "string", required: false, source: "outputs"),
                ]),
        ]
    }
    func resolve(_ target: AutomationTarget) throws -> (AudioDevice, String) {
        var uid: String
        let direction: String
        switch target {
        case .device(let value, let d):
            uid = value
            direction = d
        case .selector("defaultOutput"):
            uid = engine.deviceVolumeMonitor.defaultDeviceUID ?? ""
            direction = "output"
        case .selector("defaultInput"):
            uid = engine.deviceVolumeMonitor.defaultInputDeviceUID ?? ""
            direction = "input"
        default: throw AutomationError(.invalidParameter, "Device target required")
        }
        guard
            let device = (direction == "input" ? engine.inputDevices : engine.outputDevices).first(where: {
                $0.uid == uid
            })
        else { throw AutomationError(.unavailable, "Device is disconnected") }
        uid = device.uid
        return (device, direction)
    }
    func state(_ device: AudioDevice, direction: String) -> AutomationValue {
        let monitor = engine.deviceVolumeMonitor
        let concrete = monitor as? DeviceVolumeMonitor
        let volume = direction == "input" ? concrete?.inputVolumes[device.id] : monitor.volumes[device.id]
        let muted =
            direction == "input" ? concrete?.inputMuteStates[device.id] : monitor.muteStates[device.id]
        let isDefault =
            direction == "input"
            ? monitor.defaultInputDeviceUID == device.uid : monitor.defaultDeviceUID == device.uid
        return .object([
            "deviceUID": .string(device.uid), "name": .string(device.name), "direction": .string(direction),
            "volumePercent": volume.map { .number(Double($0) * 100) } ?? .null,
            "muted": muted.map { .bool($0) } ?? .null, "default": .bool(isDefault),
            "backend": direction == "output"
                ? .string(monitor.outputVolumeBackend(for: device.id).rawValue) : .string("hardware"),
            "hidden": .bool(
                (direction == "input"
                    ? engine.settingsManager.hiddenInputDeviceUIDs
                    : engine.settingsManager.hiddenOutputDeviceUIDs).contains(device.uid)),
            "sampleRate": .number((try? device.id.readNominalSampleRate()) ?? 0),
            "availableSampleRates": .array(device.id.readAvailableSampleRates().map { .number($0) }),
            "hogModeOwner": .number(Double(device.id.readHogModeOwner())),
        ])
    }
    func snapshot() -> AutomationValue {
        .object([
            "devices": .array(
                engine.outputDevices.map { state($0, direction: "output") }
                    + engine.inputDevices.map { state($0, direction: "input") }),
            "alertVolumePercent": (engine.deviceVolumeMonitor as? DeviceVolumeMonitor).map {
                .number(Double($0.alertVolume) * 100)
            } ?? .null,
        ])
    }
    func requiresAsync(method: String, params: [String: AutomationValue]) throws -> Bool {
        guard
            ["device.volume.set", "device.volume.step", "device.mute.set", "device.mute.toggle"].contains(
                method)
        else { return false }
        let (device, direction) = try resolve(AutomationTarget.parse(params["target"]))
        return direction == "output" && engine.deviceVolumeMonitor.outputVolumeBackend(for: device.id) == .ddc
    }
    func execute(method: String, params: [String: AutomationValue]) async throws -> AutomationValue {
        let p = AutomationParameters(params)
        let settings = engine.settingsManager
        if method == "device.list" { return snapshot() }
        if method == "device.priority.set" {
            let direction = try p.choice("direction", ["input", "output"])
            let uids = try p.strings("deviceUIDs")
            guard Set(uids).count == uids.count else {
                throw AutomationError(.invalidParameter, "Duplicate priority UID")
            }
            if direction == "input" {
                settings.setInputDevicePriorityOrder(uids)
            } else {
                settings.setDevicePriorityOrder(uids)
            }
            return .object(["status": .string("stored")])
        }
        if method == "device.hidden.set" || method.hasPrefix("device.icon.") {
            guard case .device(let uid, let direction) = try AutomationTarget.parse(params["target"]) else {
                throw AutomationError(.invalidParameter, "Explicit device UID required")
            }
            if method == "device.hidden.set" {
                let hide = try p.bool("hidden")
                if direction == "input" {
                    if hide {
                        settings.hideInputDevice(uid: uid)
                    } else {
                        settings.unhideInputDevice(uid: uid)
                    }
                } else {
                    if hide {
                        settings.hideOutputDevice(uid: uid)
                    } else {
                        settings.unhideOutputDevice(uid: uid)
                    }
                }
            } else {
                let symbol = method == "device.icon.clear" ? nil : try p.string("symbol")
                if let symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
                    throw AutomationError(.invalidParameter, "Unknown symbol", field: "symbol")
                }
                settings.setDeviceIconOverride(for: uid, to: symbol)
            }
            return .object(["status": .string("stored")])
        }
        if method == "input.lock.set" {
            let enabled = try p.bool("enabled")
            if params["deviceUID"] != nil {
                let uid = try p.string("deviceUID")
                guard let device = engine.inputDevices.first(where: { $0.uid == uid }) else {
                    throw AutomationError(.unavailable, "Input device is disconnected")
                }
                guard engine.setLockedInputDevice(device) else {
                    throw AutomationError(.unavailable, "Input selection failed; lock unchanged")
                }
            }
            var value = settings.appSettings
            value.lockInputDevice = enabled
            settings.appSettings = value
            return .object(["status": .string("applied")])
        }
        if method.hasPrefix("alert.") {
            guard let m = engine.deviceVolumeMonitor as? DeviceVolumeMonitor else {
                throw AutomationError(.unavailable, "Alert control unavailable")
            }
            if method == "alert.routing.set" {
                if try p.bool("followDefault") {
                    m.setSystemFollowDefault()
                    guard (try? AudioDeviceID.readSystemOutputDevice()) == m.defaultDeviceID else {
                        throw AutomationError(.unavailable, "Alert routing was not confirmed")
                    }
                } else {
                    let uid = try p.string("deviceUID")
                    guard let device = engine.outputDevices.first(where: { $0.uid == uid }) else {
                        throw AutomationError(.unavailable, "Alert device is disconnected")
                    }
                    m.setSystemDeviceExplicit(device.id)
                    guard (try? AudioDeviceID.readSystemOutputDevice()) == device.id else {
                        throw AutomationError(.unavailable, "Alert routing was not confirmed")
                    }
                }
            } else {
                let volume =
                    method == "alert.volume.set"
                    ? try p.number("percent", range: 0...100)
                    : max(
                        0, min(100, Double(m.alertVolume) * 100 + (try p.number("delta", range: -100...100))))
                try await m.automationSetAlertVolume(Float(volume / 100))
            }
            return .object(["status": .string("applied"), "state": snapshot()])
        }
        let (device, direction) = try resolve(AutomationTarget.parse(params["target"]))
        if method == "device.get" { return state(device, direction: direction) }
        let m = engine.deviceVolumeMonitor
        switch method {
        case "device.volume.set", "device.volume.step":
            let current =
                direction == "input"
                ? (m as? DeviceVolumeMonitor)?.inputVolumes[device.id] : m.volumes[device.id]
            let percent =
                method == "device.volume.set"
                ? try p.number("percent", range: 0...100)
                : max(0, min(100, Double(current ?? 1) * 100 + (try p.number("delta", range: -100...100))))
            if direction == "input" {
                guard let c = m as? DeviceVolumeMonitor, current != nil else {
                    throw AutomationError(.unavailable, "Input volume unsupported")
                }
                c.setInputVolume(for: device.id, to: Float(percent / 100))
            } else {
                #if !APP_STORE
                    if m.outputVolumeBackend(for: device.id) == .ddc {
                        do {
                            try await engine.ddcController.automationSetVolume(
                                for: device.id, to: Int(percent.rounded()))
                        } catch {
                            throw AutomationError(.unavailable, "DDC volume write could not be confirmed")
                        }
                    } else {
                        m.setVolume(for: device.id, to: Float(percent / 100))
                    }
                #else
                    m.setVolume(for: device.id, to: Float(percent / 100))
                #endif
                m.refreshOutputDeviceStates()
            }
            let observed =
                direction == "input"
                ? (m as? DeviceVolumeMonitor)?.inputVolumes[device.id] : m.volumes[device.id]
            guard let observed, abs(Double(observed) * 100 - percent) <= 1 else {
                throw AutomationError(.unavailable, "Volume write was not confirmed")
            }
        case "device.mute.set", "device.mute.toggle":
            let current =
                direction == "input"
                ? (m as? DeviceVolumeMonitor)?.inputMuteStates[device.id] : m.muteStates[device.id]
            guard let current else { throw AutomationError(.unavailable, "Device mute unsupported") }
            let muted = method == "device.mute.set" ? try p.bool("muted") : !current
            if direction == "input" {
                (m as? DeviceVolumeMonitor)?.setInputMute(for: device.id, to: muted)
            } else {
                #if !APP_STORE
                    if m.outputVolumeBackend(for: device.id) == .ddc {
                        do {
                            try await engine.ddcController.automationSetMute(for: device.id, to: muted)
                        } catch {
                            throw AutomationError(.unavailable, "DDC mute write could not be confirmed")
                        }
                    } else {
                        m.setMute(for: device.id, to: muted)
                    }
                #else
                    m.setMute(for: device.id, to: muted)
                #endif
                m.refreshOutputDeviceStates()
            }
            let observed =
                direction == "input"
                ? (m as? DeviceVolumeMonitor)?.inputMuteStates[device.id] : m.muteStates[device.id]
            guard observed == muted else {
                throw AutomationError(.unavailable, "Mute write was not confirmed")
            }
        case "device.default.set":
            let ok =
                direction == "input"
                ? engine.setLockedInputDevice(device) : engine.setDefaultOutputDevice(device.id)
            guard ok else { throw AutomationError(.unavailable, "Default device selection refused") }
        case "device.volumeBackend.set":
            guard direction == "output" else {
                throw AutomationError(.invalidParameter, "Output device required")
            }
            let backend = try p.choice("backend", ["auto", "software"])
            settings.setDeviceVolumeTierOverride(for: device.uid, to: backend == "auto" ? nil : .software)
            m.applyTierOverrideChange(for: device.id)
        case "device.sampleRate.set":
            let rate = try p.number("sampleRate", range: 8000...768000)
            guard device.id.readAvailableSampleRates().contains(rate) else {
                throw AutomationError(.unavailable, "Sample rate unsupported")
            }
            do { try device.id.writeNominalSampleRate(rate) } catch {
                throw AutomationError(.unavailable, "Device refused sample rate")
            }
        default: throw AutomationError(.unknownMethod, "Unknown device operation")
        }
        return .object(["status": .string("applied"), "state": state(device, direction: direction)])
    }
}
