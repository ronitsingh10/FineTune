// FineTune/Audio/Monitors/AudioProcessMonitor.swift
import AppKit
import AudioToolbox
import os

/// Lightweight value for detecting process list changes without comparing icons/names.
private struct AppFingerprint: Hashable {
    let pid: pid_t
    let objectIDs: [AudioObjectID]
}

@Observable
@MainActor
final class AudioProcessMonitor {
    private(set) var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioProcessMonitor")

    /// Bundle ID prefixes for system daemons that should be filtered from the apps list
    /// These produce system audio (Siri, alerts, notifications) and shouldn't appear as user apps
    private static let systemDaemonPrefixes: [String] = [
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistant",
        "com.apple.audio",
        "com.apple.coreaudio",
        "com.apple.mediaremote",
        "com.apple.accessibility.heard",
        "com.apple.hearingd",
        "com.apple.voicebankingd",
        "com.apple.systemsound",
        "com.apple.FrontBoardServices",
        "com.apple.frontboard",
        "com.apple.springboard",
        "com.apple.notificationcenter",
        "com.apple.NotificationCenter",
        "com.apple.UserNotifications",
        "com.apple.usernotifications",
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech",
        "com.apple.dictation",
        "com.apple.corespeech",
        "com.apple.CoreSpeech",
        "com.apple.VoiceControl",
        "com.apple.voicecontrol",
    ]

    /// Process names for system daemons (fallback when bundle ID is nil or different format)
    private static let systemDaemonNames: [String] = [
        "systemsoundserverd",
        "systemsoundserv",
        "coreaudiod",
        "audiomxd",
        "speechrecognitiond",
        "dictationd",
        "corespeech",
    ]

    /// Returns true if the bundle ID or process name indicates a system daemon that should be filtered
    private func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        // Check bundle ID prefixes
        if let bundleID {
            if Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
        }

        // Check process name (handles nil bundleID and format variations)
        let lowercaseName = name.lowercased()
        if Self.systemDaemonNames.contains(where: { lowercaseName.hasPrefix($0) }) {
            return true
        }

        return false
    }

    // Property listeners
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var monitoredProcesses: Set<AudioObjectID> = []
    private var periodicRefreshTask: Task<Void, Never>?

    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Function type for the private responsibility API
    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t

    /// Gets the "responsible" PID for a process using Apple's private API.
    /// This is what Activity Monitor uses to show the correct parent for XPC services.
    private func getResponsiblePID(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let responsiblePID = unsafeBitCast(symbol, to: ResponsibilityFunc.self)(pid)
        return responsiblePID > 0 && responsiblePID != pid ? responsiblePID : nil
    }

    /// Finds the responsible application for a helper/XPC process.
    /// Uses Apple's responsibility API first, falls back to process tree walking.
    private func findResponsibleApp(
        for pid: pid_t,
        in runningAppsByPID: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        // First try Apple's responsibility API (works for XPC services like Safari's WebKit processes)
        if let responsiblePID = getResponsiblePID(for: pid),
           let app = runningAppsByPID[responsiblePID],
           app.bundleURL?.pathExtension == "app" {
            return app
        }

        // Fall back to walking up the process tree (works for Chrome/Brave helpers)
        var currentPID = pid
        var visited = Set<pid_t>()

        while currentPID > 1 && !visited.contains(currentPID) {
            visited.insert(currentPID)

            // Check if this PID is a proper app bundle (.app, not .xpc service)
            if let app = runningAppsByPID[currentPID],
               app.bundleURL?.pathExtension == "app" {
                return app
            }

            // Get parent PID using sysctl
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, currentPID]

            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }

            let parentPID = info.kp_eproc.e_ppid
            if parentPID == currentPID { break }
            currentPID = parentPID
        }

        return nil
    }

    func start() {
        guard processListListenerBlock == nil else { return }

        logger.debug("Starting audio process monitor")

        // Set up listener first
        processListListenerBlock = { [weak self] numberAddresses, addresses in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            .system,
            &processListAddress,
            .main,
            processListListenerBlock!
        )

        if status != noErr {
            logger.error("Failed to add process list listener: \(status)")
        }

        // Initial refresh
        refresh()

        // Periodic refresh as safety net — CoreAudio property listeners can miss
        // notifications during rapid process lifecycle changes (quit + relaunch).
        startPeriodicRefresh()
    }

    func stop() {
        logger.debug("Stopping audio process monitor")

        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil

        // Remove process list listener
        if let block = processListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &processListAddress, .main, block)
            processListListenerBlock = nil
        }

        // Remove all per-process listeners
        removeAllProcessListeners()
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    private func refresh() {
        do {
            let processIDs = try AudioObjectID.readProcessList()
            let runningApps = NSWorkspace.shared.runningApplications
            let runningAppsByPID = Dictionary(
                runningApps.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let myPID = ProcessInfo.processInfo.processIdentifier

            var appsByPID: [pid_t: AudioApp] = [:]

            for objectID in processIDs {
                guard let pid = try? objectID.readProcessPID(), pid != myPID else { continue }
                guard objectID.readProcessIsRunning() else { continue }

                // Try to find the parent app (for helper processes like Safari Graphics and Media)
                let directApp = runningAppsByPID[pid]

                // Check if it's a real app bundle (.app), not an XPC service (.xpc)
                let isRealApp = directApp?.bundleURL?.pathExtension == "app"
                let resolvedApp = isRealApp ? directApp : findResponsibleApp(for: pid, in: runningAppsByPID)
                let parentPID = resolvedApp?.processIdentifier ?? pid
                let isHelper = parentPID != pid

                // Use resolved app's info, fall back to Core Audio bundle ID
                let name = resolvedApp?.localizedName
                    ?? objectID.readProcessBundleID()?.components(separatedBy: ".").last
                    ?? "Unknown"
                let icon = resolvedApp?.icon
                    ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let bundleID = resolvedApp?.bundleIdentifier ?? objectID.readProcessBundleID()

                // Skip system daemons (siri, coreaudio, etc.) - they shouldn't appear in the apps list
                if isSystemDaemon(bundleID: bundleID, name: name) { continue }

                // Merge helper process objectIDs into parent app entry
                if let existing = appsByPID[parentPID] {
                    if !existing.processObjectIDs.contains(objectID) {
                        var mergedIDs = existing.processObjectIDs
                        mergedIDs.append(objectID)
                        mergedIDs.sort()
                        appsByPID[parentPID] = AudioApp(
                            id: existing.id,
                            processObjectIDs: mergedIDs,
                            name: existing.name,
                            icon: existing.icon,
                            bundleID: existing.bundleID,
                            isHelperBacked: existing.isHelperBacked || isHelper
                        )
                    }
                } else {
                    appsByPID[parentPID] = AudioApp(
                        id: parentPID,
                        processObjectIDs: [objectID],
                        name: name,
                        icon: icon,
                        bundleID: bundleID,
                        isHelperBacked: isHelper
                    )
                }
            }

            // Update per-process listeners
            updateProcessListeners(for: processIDs)

            let sorted = appsByPID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Only fire callback if the app list actually changed (avoids churn from periodic refresh)
            let oldSet = Set(activeApps.map { AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs) })
            let newSet = Set(sorted.map { AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs) })

            activeApps = sorted
            if oldSet != newSet {
                onAppsChanged?(activeApps)
            }

        } catch {
            logger.error("Failed to refresh process list: \(error.localizedDescription)")
        }
    }

    private func updateProcessListeners(for processIDs: [AudioObjectID]) {
        let currentSet = Set(processIDs)

        // Remove listeners for processes that are gone
        let removed = monitoredProcesses.subtracting(currentSet)
        for objectID in removed {
            removeProcessListener(for: objectID)
        }

        // Add listeners for new processes
        let added = currentSet.subtracting(monitoredProcesses)
        for objectID in added {
            addProcessListener(for: objectID)
        }

        monitoredProcesses = currentSet
    }

    private func addProcessListener(for objectID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)

        if status == noErr {
            processListenerBlocks[objectID] = block
        } else {
            logger.warning("Failed to add isRunning listener for \(objectID): \(status)")
        }
    }

    private func removeProcessListener(for objectID: AudioObjectID) {
        guard let block = processListenerBlocks.removeValue(forKey: objectID) else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }

    private func removeAllProcessListeners() {
        for objectID in monitoredProcesses {
            removeProcessListener(for: objectID)
        }
        monitoredProcesses.removeAll()
        processListenerBlocks.removeAll()
    }

}
