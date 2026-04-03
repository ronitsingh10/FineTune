// FineTune/Views/EQPanelView.swift
import SwiftUI

struct EQPanelView: View {
    @Binding var settings: EQSettings
    let userPresets: [UserEQPreset]
    let onPresetSelected: (EQPreset) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSettingsChanged: (EQSettings) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    @State private var isSaving = false
    @State private var savePresetName = ""
    @FocusState private var isSaveFieldFocused: Bool

    private let frequencyLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    // MARK: - Preset Matching

    /// Finds the matching built-in preset for the current band gains, if any.
    private var currentBuiltInPreset: EQPreset? {
        EQPreset.allCases.first { $0.settings.bandGains == settings.bandGains }
    }

    /// Finds the matching user preset for the current band gains, if any.
    private var currentUserPreset: UserEQPreset? {
        userPresets.first { $0.settings.bandGains == settings.bandGains }
    }

    /// The currently selected picker item (built-in, user, or nil for "Custom").
    private var selectedPickerItem: EQPickerItem? {
        if let builtIn = currentBuiltInPreset {
            return EQPickerItem(builtIn: builtIn)
        } else if let user = currentUserPreset {
            return EQPickerItem(user: user)
        }
        return nil
    }

    /// Whether the current curve is custom (doesn't match any preset).
    private var isCustomCurve: Bool { selectedPickerItem == nil }

    var body: some View {
        // Entire EQ panel content inside recessed background
        VStack(spacing: 12) {
            // Header: Toggle left, save field or spacer in middle, Preset right
            HStack {
                // EQ toggle on left
                HStack(spacing: 6) {
                    Toggle("", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .labelsHidden()
                        .onChange(of: settings.isEnabled) { _, _ in
                            onSettingsChanged(settings)
                        }
                    Text("EQ")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(.primary)
                }

                if isSaving {
                    // Save field fills the middle gap
                    savePresetField
                        .transition(.blurReplace.combined(with: .opacity))
                } else {
                    Spacer()

                    // Save button (visible when curve is custom)
                    if isCustomCurve {
                        saveButton
                            .transition(.blurReplace.combined(with: .opacity))
                    }
                }

                // Preset picker on right (always visible)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text("Preset")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)

                    EQPresetPicker(
                        selectedItem: selectedPickerItem,
                        userPresets: userPresets,
                        onBuiltInSelected: onPresetSelected,
                        onUserPresetSelected: onUserPresetSelected,
                        onDeleteUserPreset: onDeleteUserPreset,
                        onRenameUserPreset: onRenameUserPreset
                    )
                }
            }
            .zIndex(1)  // Ensure dropdown renders above sliders

            // 10-band sliders
            HStack(spacing: 22) {
                ForEach(0..<10, id: \.self) { index in
                    EQSliderView(
                        frequency: frequencyLabels[index],
                        gain: Binding(
                            get: { settings.bandGains[index] },
                            set: { newValue in
                                settings.bandGains[index] = newValue
                                onSettingsChanged(settings)
                            }
                        )
                    )
                    .frame(width: 26, height: 100)
                }
            }
            .opacity(settings.isEnabled ? 1.0 : 0.3)
            .allowsHitTesting(settings.isEnabled)
            .animation(.easeInOut(duration: 0.2), value: settings.isEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .animation(DesignTokens.Animation.quick, value: isSaving)
        // No outer background - parent ExpandableGlassRow provides the glass container
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            savePresetName = ""
            isSaving = true
            Task { @MainActor in
                isSaveFieldFocused = true
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        }
        .buttonStyle(.plain)
        .help("Save current EQ as preset")
        .accessibilityLabel("Save current EQ curve as a new preset")
    }

    // MARK: - Save Preset Field

    private var savePresetField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            TextField("Preset name", text: $savePresetName)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($isSaveFieldFocused)
                .onSubmit { commitSave() }
                .onExitCommand { cancelSave() }

            Button {
                commitSave()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        savePresetName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? DesignTokens.Colors.textTertiary
                            : DesignTokens.Colors.accentPrimary
                    )
            }
            .buttonStyle(.plain)
            .disabled(savePresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Save preset")
            .accessibilityLabel("Confirm save preset")

            Button {
                cancelSave()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel saving preset")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.menuBorderHover, lineWidth: 0.5)
        }
    }

    // MARK: - Save Actions

    private func commitSave() {
        let trimmed = savePresetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Store with isEnabled = true — isEnabled is per-app state, not preset state
        var presetSettings = settings
        presetSettings.isEnabled = true
        onSavePreset(trimmed, presetSettings)
        isSaving = false
        savePresetName = ""
    }

    private func cancelSave() {
        isSaving = false
        savePresetName = ""
    }
}

// MARK: - Previews

#Preview {
    // Simulating how it appears inside ExpandableGlassRow
    VStack {
        EQPanelView(
            settings: .constant(EQSettings()),
            userPresets: [
                UserEQPreset(name: "My Bass", settings: EQSettings(bandGains: [6, 5, 4, 0, 0, 0, 0, 0, 0, 0]))
            ],
            onPresetSelected: { _ in },
            onUserPresetSelected: { _ in },
            onSettingsChanged: { _ in },
            onSavePreset: { _, _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .background {
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
            .fill(DesignTokens.Colors.recessedBackground)
    }
    .frame(width: 550)
    .padding()
    .background(Color.black)
}

#Preview("Custom Curve - Save Visible") {
    VStack {
        EQPanelView(
            settings: .constant(EQSettings(bandGains: [3, 2, 1, 0, -1, 0, 2, 3, 1, 0])),
            userPresets: [],
            onPresetSelected: { _ in },
            onUserPresetSelected: { _ in },
            onSettingsChanged: { _ in },
            onSavePreset: { _, _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .frame(width: 550)
    .padding()
    .background(Color.black)
}
