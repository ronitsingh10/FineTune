// FineTune/Views/Settings/Tabs/AudioTab.swift
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                callDuckingSection
                devicesSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.callDucking.enabled) { _, _ in
            audioEngine.handleCallDuckingSettingsChanged()
        }
        .onChange(of: settings.appSettings.callDucking.boostDecibels) { _, _ in
            audioEngine.handleCallDuckingSettingsChanged()
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 280
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Loudness Compensation",
                description: "Boost low frequencies at low volume"
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Call Ducking Compensation

    private var callDuckingBoostBinding: Binding<Float> {
        Binding(
            get: { settings.appSettings.callDucking.boostDecibels },
            set: { settings.appSettings.callDucking.boostDecibels = $0 }
        )
    }

    private var callDuckingStatusText: String {
        guard settings.appSettings.callDucking.enabled else {
            return "Disabled. Other apps will be ducked during calls."
        }
        if audioEngine.voipCallDetector.isCallActive {
            let names = audioEngine.voipCallDetector.activeCallBundleIDs
                .sorted()
                .map { $0.split(separator: ".").last.map(String.init) ?? $0 }
                .joined(separator: ", ")
            return "Active — boosting other apps by \(Int(settings.appSettings.callDucking.boostDecibels)) dB to compensate for: \(names)."
        }
        return "Idle — will kick in when a recognised call app starts."
    }

    private var callDuckingSection: some View {
        SettingsSection("Call Ducking Compensation") {
            SettingsRow(
                "Enable",
                description: "When a VoIP / video call is active, automatically boost every other app to undo macOS's automatic ducking. macOS reduces all other audio by roughly 20 dB during FaceTime / WhatsApp / Zoom / etc. calls — this counter-boost cancels it out."
            ) {
                Toggle("", isOn: $settings.appSettings.callDucking.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Boost Amount",
                description: "How much to amplify other apps while a call is active. macOS ducks roughly 20 dB by default; start there and adjust to taste."
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Slider(
                        value: Binding(
                            get: { Double(callDuckingBoostBinding.wrappedValue) },
                            set: { callDuckingBoostBinding.wrappedValue = Float($0) }
                        ),
                        in: 6.0...24.0,
                        step: 1.0
                    )
                    .frame(width: 280)
                    .disabled(!settings.appSettings.callDucking.enabled)
                    Text("\(Int(settings.appSettings.callDucking.boostDecibels)) dB")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Dimensions.settingsPercentageWidth, alignment: .trailing)
                }
            }
            SettingsRowDivider()
            SettingsRow(
                "Status",
                description: callDuckingStatusText
            ) {
                EmptyView()
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection("Devices") {
            SettingsRow(
                "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "System Sounds",
                description: "Where alerts and effects play"
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Alert Volume",
                description: "Volume for alerts and notifications"
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: 280
                )
            }
            .task {
                // No CoreAudio listener for alert volume — must poll via AppleScript.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}
