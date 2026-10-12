import Foundation

/// App-scoped lifecycle and opt-in boundary; clients cannot enable this themselves.
@MainActor
final class AutomationRuntime {
    let service: AutomationService
    let broker: AutomationStateBroker
    let server: AutomationSocketServer
    let discoveryURL: URL
    let engine: AudioEngine
    var onSettingsEffects: ((AppSettings, AppSettings) -> Void)?
    private var disableTask: Task<Void, Never>?
    init(
        engine: AudioEngine, resolver: (any TargetAppResolving)?, popup: PopupVisibilityService,
        controller: any MenuBarPopupControlling, discoveryURL: URL? = nil
    ) {
        self.engine = engine
        let service = AutomationService(engine: engine, resolver: resolver)
        let broker = AutomationStateBroker(service: service)
        self.service = service
        self.broker = broker
        service.adapters.append(
            PresentationAutomationAdapter(engine: engine, popup: popup, controller: controller))
        self.server = AutomationSocketServer(
            handler: { request in
                guard await engine.settingsManager.appSettings.automationEnabled else {
                    return .init(id: request.id, error: .init(.unavailable, "Automation disabled"))
                }
                return await service.execute(request)
            }, subscription: { await broker.subscribe() })
        self.discoveryURL =
            discoveryURL ?? FineTuneDirectories.base.appendingPathComponent("Automation/discovery.json")
        let previous = engine.settingsManager.onAppSettingsChanged
        engine.settingsManager.onAppSettingsChanged = { [weak self] old, new in
            previous?(old, new)
            guard let self else { return }
            self.onSettingsEffects?(old, new)
            if old.automationEnabled != new.automationEnabled {
                self.disableTask?.cancel()
                if new.automationEnabled {
                    self.reconcile()
                } else {
                    // Gate requests immediately; allow a reset response to drain before closing.
                    self.disableTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        self?.reconcile()
                    }
                }
            }
        }
    }
    func reconcile() {
        if engine.settingsManager.appSettings.automationEnabled {
            do {
                try server.start(discoveryURL: discoveryURL, instanceId: service.instanceId)
                engine.settingsManager.automationStatus = "Enabled"
            } catch { engine.settingsManager.automationStatus = "Unavailable: could not start the local API" }
        } else {
            stop()
            engine.settingsManager.automationStatus = "Disabled"
        }
    }
    func stop() {
        server.stop()
        broker.stop()
        service.operations.cancelAll()
    }
}

nonisolated enum FineTuneDirectories {
    static var base: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if FINETUNE_CUSTOM_BUILD
            return support.appendingPathComponent("FineTune-Automation")
        #else
            return support.appendingPathComponent("FineTune")
        #endif
    }
}
