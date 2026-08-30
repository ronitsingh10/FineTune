// FineTune/Audio/AUPlugins/AUPluginScanner.swift
import AudioToolbox
import Foundation
import os

@Observable
@MainActor
final class AUPluginScanner {
    private(set) var plugins: [AUPluginDescriptor] = []
    private(set) var manufacturers: [String: [AUPluginDescriptor]] = [:]
    private(set) var hasNewPlugins = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AUPluginScanner")
    private nonisolated(unsafe) var registrationObserver: NSObjectProtocol?

    init() {
        refresh()
        registrationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kAudioComponentRegistrationsChangedNotification as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
            self?.hasNewPlugins = true
        }
    }

    deinit {
        let observer = registrationObserver
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        var result: [AUPluginDescriptor] = []

        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var desc = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            var component: AudioComponent? = nil
            repeat {
                component = AudioComponentFindNext(component, &desc)
                if let component {
                    var componentDesc = AudioComponentDescription()
                    AudioComponentGetDescription(component, &componentDesc)
                    result.append(AUPluginDescriptor(component: component, description: componentDesc))
                }
            } while component != nil
        }

        result.sort { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
        plugins = result
        manufacturers = Dictionary(grouping: result, by: \.manufacturer)
        logger.info("Scanned \(result.count) Audio Unit effect plugins from \(self.manufacturers.count) manufacturers")
    }

    func clearNewPluginsFlag() {
        hasNewPlugins = false
    }

    func findComponent(for descriptor: AUPluginDescriptor) -> AudioComponent? {
        var desc = descriptor.audioComponentDescription
        return AudioComponentFindNext(nil, &desc)
    }
}
