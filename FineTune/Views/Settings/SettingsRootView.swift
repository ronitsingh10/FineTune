// FineTune/Views/Settings/SettingsRootView.swift
import SwiftUI

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry
    @ObservedObject var updateManager: UpdateManager
    let onResetCache: () -> Void

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case general, audio, shortcuts, updates, about
        var id: Self { self }
    }

    @State private var selection: Section = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralTab(
                settings: settings,
                onResetAll: {
                    audioEngine.handleSettingsReset()
                    deviceVolumeMonitor.setSystemFollowDefault()
                },
                onResetCache: {
                    audioEngine.handleAudioCacheReset()
                }
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(Section.general)

            AudioTab(
                settings: settings,
                audioEngine: audioEngine,
                deviceVolumeMonitor: deviceVolumeMonitor
            )
            .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            .tag(Section.audio)

            ShortcutsTab(
                settings: settings,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry
            )
            .tabItem { Label("Shortcuts", systemImage: "command") }
            .tag(Section.shortcuts)

            UpdatesTab(updateManager: updateManager)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Section.updates)

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Section.about)
        }
        .frame(width: 720, height: 560)
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
        .background(WindowTitleBridge(title: "FineTune Settings"))
    }
}
