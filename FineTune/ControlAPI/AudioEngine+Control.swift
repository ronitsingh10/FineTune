import Foundation

extension AudioEngine: ControlEngine {
    func controlState() -> ControlJSON {
        let appRows = apps.sorted {
            if $0.persistenceIdentifier == $1.persistenceIdentifier { return $0.id < $1.id }
            return $0.persistenceIdentifier < $1.persistenceIdentifier
        }.map { app -> ControlJSON in
            let requested: ControlJSON
            if getDeviceSelectionMode(for: app) == .multi {
                requested = .object([
                    "mode": .string("multi"),
                    "deviceUIDs": .array(getSelectedDeviceUIDs(for: app).sorted().map(ControlJSON.string))
                ])
            } else if isFollowingDefault(for: app) || getDeviceUID(for: app) == nil {
                requested = .object(["mode": .string("followDefault")])
            } else {
                requested = .object(["mode": .string("single"), "deviceUID": .optional(getDeviceUID(for: app))])
            }
            let applied = controlAppliedDeviceUIDs(for: app.id)
            let routing = controlRouting[app.id]
            return .object([
                "appId": .string(app.persistenceIdentifier), "pids": .array([.number(Double(app.id))]),
                "name": .string(app.name), "active": .bool(true),
                "volume": .number(Double(getVolume(for: app))), "boost": .number(Double(getBoost(for: app).rawValue)),
                "muted": .bool(getMute(for: app)),
                "routing": .object([
                    "requested": requested,
                    "appliedDeviceUIDs": applied.map { .array($0.map(ControlJSON.string)) } ?? .null,
                    "status": .string(routing?.status ?? (applied == nil ? "unavailable" : "applied")),
                    "error": routing?.error?.json ?? .null
                ])
            ])
        }
        var devices: [ControlJSON] = []
        for (direction, connected) in [("input", inputDevices), ("output", outputDevices)] {
            for device in connected.sorted(by: { $0.uid < $1.uid }) {
                let input = direction == "input"
                let readback = (deviceVolumeMonitor as? DeviceVolumeMonitor)?.controlReadback(for: device.id, input: input)
                devices.append(.object([
                    "uid": .string(device.uid), "name": .string(device.name), "direction": .string(direction),
                    "isDefault": .bool(device.uid == (input ? deviceVolumeMonitor.defaultInputDeviceUID : deviceVolumeMonitor.defaultDeviceUID)),
                    "volume": .optional(readback?.volume), "muted": .optional(readback?.muted),
                    "volumeSource": .optional(readback?.source),
                    "capabilities": .object([
                        "volumeReadable": .bool(readback?.volume != nil),
                        "muteReadable": .bool(readback?.muted != nil), "selectable": .bool(true)
                    ])
                ]))
            }
        }
        let permissionStatus: String
        switch permission.status {
        case .unknown: permissionStatus = "unknown"
        case .authorized: permissionStatus = "authorized"
        case .denied: permissionStatus = "denied"
        }
        #if ENABLE_TCC_SPI
        let permissionSource = "preflight"
        #else
        let permissionSource = "assumed"
        #endif
        return .object([
            "apps": .array(appRows), "devices": .array(devices),
            "defaultOutput": .optional(deviceVolumeMonitor.defaultDeviceUID),
            "defaultInput": .optional(deviceVolumeMonitor.defaultInputDeviceUID),
            "inputPolicy": .object([
                "lockEnabled": .bool(settingsManager.appSettings.lockInputDevice),
                "preferredDeviceUID": .optional(settingsManager.preferredInputDeviceUID),
                "lockedDeviceUID": .optional(settingsManager.lockedInputDeviceUID)
            ]),
            "permission": .object(["audioCapture": .string(permissionStatus), "source": .string(permissionSource)])
        ])
    }

    func performControlCommand(_ command: ControlCommand) throws {
        func resolve(_ appID: String, _ pid: Int32?) throws -> AudioApp {
            let matches = apps.filter { $0.persistenceIdentifier == appID }
            if let pid {
                guard let app = matches.first(where: { $0.id == pid }) else {
                    throw ControlFailure(code: "staleApp", message: "The process no longer matches this app")
                }
                return app
            }
            guard !matches.isEmpty else { throw ControlFailure(code: "appNotFound", message: "App is not active") }
            guard matches.count == 1 else { throw ControlFailure(code: "ambiguousApp", message: "Specify a current process ID") }
            return matches[0]
        }
        func requireCapture() throws {
            guard permission.status == .authorized else {
                throw ControlFailure(code: "permissionDenied", message: "Audio capture permission is required")
            }
        }
        switch command {
        case .getState, .subscribe: break
        case .volume(let appID, let pid, let volume):
            let app = try resolve(appID, pid)
            try requireCapture()
            setVolume(for: app, to: volume)
        case .mute(let appID, let pid, let muted):
            let app = try resolve(appID, pid)
            try requireCapture()
            setMute(for: app, to: muted)
        case .routing(let appID, let pid, let uid):
            let app = try resolve(appID, pid)
            try requireCapture()
            guard getDeviceSelectionMode(for: app) != .multi else {
                throw ControlFailure(code: "unsupportedRouting", message: "Multi-output routing is read-only")
            }
            if let uid, !outputDevices.contains(where: { $0.uid == uid }) {
                throw ControlFailure(code: "deviceNotFound", message: "Output device is not connected")
            }
            setDevice(for: app, deviceUID: uid)
        case .defaultOutput(let uid):
            guard let device = outputDevices.first(where: { $0.uid == uid }) else {
                throw ControlFailure(code: "deviceNotFound", message: "Output device is not connected")
            }
            guard setDefaultOutputDevice(device.id) else {
                throw ControlFailure(code: "commandFailed", message: "Unable to select output device")
            }
        case .preferredInput(let uid):
            guard let device = inputDevices.first(where: { $0.uid == uid }) else {
                throw ControlFailure(code: "deviceNotFound", message: "Input device is not connected")
            }
            guard setLockedInputDevice(device) else {
                throw ControlFailure(code: "commandFailed", message: "Unable to select input device")
            }
        }
    }
}
