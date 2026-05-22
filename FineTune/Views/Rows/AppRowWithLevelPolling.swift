// FineTune/Views/Rows/AppRowWithLevelPolling.swift
import SwiftUI

/// App row that polls audio levels at regular intervals
struct AppRowWithLevelPolling: View {
    let app: AudioApp
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onAppActivate: () -> Void
    let eqSettings: EQSettings
    let userPresets: [UserEQPreset]
    let onEQChange: (EQSettings) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let isFocused: Bool

    // AU effect chain passthrough
    let auEffectChain: [AUEffectChainEntry]
    let isAUChainBypassed: Bool
    let auPluginScanner: AUPluginScanner?
    let getFavoriteAUPlugins: () -> Set<String>
    let getAUCrashHistory: () -> Set<String>
    let onAddAUEffect: (AUPluginDescriptor) -> Void
    let onRemoveAUEffect: (UUID) -> Void
    let onToggleAUEffect: (UUID, Bool) -> Void
    let onAUBypassToggle: () -> Void
    let onToggleAUFavorite: (String) -> Void
    let onOpenAUUI: (UUID) -> Void
    let onOpenAUGenericUI: (UUID) -> Void
    let auFailedEntryIDs: Set<UUID>
    let getAUFactoryPresets: (UUID) -> [(index: Int, name: String)]
    let onSelectAUFactoryPreset: (UUID, Int) -> Void

    @State private var displayLevel: Float = 0
    @State private var levelTimer: Timer?

    init(
        app: AudioApp,
        volume: Float,
        isMuted: Bool,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        getAudioLevel: @escaping () -> Float,
        isPopupVisible: Bool = true,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onAppActivate: @escaping () -> Void = {},
        eqSettings: EQSettings = EQSettings(),
        userPresets: [UserEQPreset] = [],
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        onUserPresetSelected: @escaping (UserEQPreset) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        isFocused: Bool = false,
        auEffectChain: [AUEffectChainEntry] = [],
        isAUChainBypassed: Bool = false,
        auPluginScanner: AUPluginScanner? = nil,
        getFavoriteAUPlugins: @escaping () -> Set<String> = { [] },
        getAUCrashHistory: @escaping () -> Set<String> = { [] },
        onAddAUEffect: @escaping (AUPluginDescriptor) -> Void = { _ in },
        onRemoveAUEffect: @escaping (UUID) -> Void = { _ in },
        onToggleAUEffect: @escaping (UUID, Bool) -> Void = { _, _ in },
        onAUBypassToggle: @escaping () -> Void = {},
        onToggleAUFavorite: @escaping (String) -> Void = { _ in },
        onOpenAUUI: @escaping (UUID) -> Void = { _ in },
        onOpenAUGenericUI: @escaping (UUID) -> Void = { _ in },
        auFailedEntryIDs: Set<UUID> = [],
        getAUFactoryPresets: @escaping (UUID) -> [(index: Int, name: String)] = { _ in [] },
        onSelectAUFactoryPreset: @escaping (UUID, Int) -> Void = { _, _ in }
    ) {
        self.app = app
        self.volume = volume
        self.isMuted = isMuted
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.getAudioLevel = getAudioLevel
        self.isPopupVisible = isPopupVisible
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onAppActivate = onAppActivate
        self.eqSettings = eqSettings
        self.userPresets = userPresets
        self.onEQChange = onEQChange
        self.onUserPresetSelected = onUserPresetSelected
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.isFocused = isFocused
        self.auEffectChain = auEffectChain
        self.isAUChainBypassed = isAUChainBypassed
        self.auPluginScanner = auPluginScanner
        self.getFavoriteAUPlugins = getFavoriteAUPlugins
        self.getAUCrashHistory = getAUCrashHistory
        self.onAddAUEffect = onAddAUEffect
        self.onRemoveAUEffect = onRemoveAUEffect
        self.onToggleAUEffect = onToggleAUEffect
        self.onAUBypassToggle = onAUBypassToggle
        self.onToggleAUFavorite = onToggleAUFavorite
        self.onOpenAUUI = onOpenAUUI
        self.onOpenAUGenericUI = onOpenAUGenericUI
        self.auFailedEntryIDs = auFailedEntryIDs
        self.getAUFactoryPresets = getAUFactoryPresets
        self.onSelectAUFactoryPreset = onSelectAUFactoryPreset
    }

    var body: some View {
        AppRow(
            app: app,
            volume: volume,
            audioLevel: displayLevel,
            devices: devices,
            selectedDeviceUID: selectedDeviceUID,
            selectedDeviceUIDs: selectedDeviceUIDs,
            isFollowingDefault: isFollowingDefault,
            defaultDeviceUID: defaultDeviceUID,
            deviceSelectionMode: deviceSelectionMode,
            isMuted: isMuted,
            boost: boost,
            onBoostChange: onBoostChange,
            onVolumeChange: onVolumeChange,
            onMuteChange: onMuteChange,
            onDeviceSelected: onDeviceSelected,
            onDevicesSelected: onDevicesSelected,
            onDeviceModeChange: onDeviceModeChange,
            onSelectFollowDefault: onSelectFollowDefault,
            onAppActivate: onAppActivate,
            eqSettings: eqSettings,
            userPresets: userPresets,
            onEQChange: onEQChange,
            onUserPresetSelected: onUserPresetSelected,
            onSavePreset: onSavePreset,
            onDeleteUserPreset: onDeleteUserPreset,
            onRenameUserPreset: onRenameUserPreset,
            isEQExpanded: isEQExpanded,
            onEQToggle: onEQToggle,
            isFocused: isFocused,
            auEffectChain: auEffectChain,
            isAUChainBypassed: isAUChainBypassed,
            auPluginScanner: auPluginScanner,
            getFavoriteAUPlugins: getFavoriteAUPlugins,
            getAUCrashHistory: getAUCrashHistory,
            onAddAUEffect: onAddAUEffect,
            onRemoveAUEffect: onRemoveAUEffect,
            onToggleAUEffect: onToggleAUEffect,
            onAUBypassToggle: onAUBypassToggle,
            onToggleAUFavorite: onToggleAUFavorite,
            onOpenAUUI: onOpenAUUI,
            onOpenAUGenericUI: onOpenAUGenericUI,
            auFailedEntryIDs: auFailedEntryIDs,
            getAUFactoryPresets: getAUFactoryPresets,
            onSelectAUFactoryPreset: onSelectAUFactoryPreset
        )
        .onAppear {
            if isPopupVisible {
                startLevelPolling()
            }
        }
        .onDisappear {
            stopLevelPolling()
        }
        .onChange(of: isPopupVisible) { _, visible in
            if visible {
                startLevelPolling()
            } else {
                stopLevelPolling()
                displayLevel = 0  // Reset meter when hidden
            }
        }
    }

    private func startLevelPolling() {
        // Guard against duplicate timers
        guard levelTimer == nil else { return }

        levelTimer = Timer.scheduledTimer(
            withTimeInterval: DesignTokens.Timing.vuMeterUpdateInterval,
            repeats: true
        ) { _ in
            displayLevel = getAudioLevel()
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}
