// FineTune/Views/Settings/Components/AccessibilityPromptStrip.swift
import SwiftUI

/// Inline strip prompting the user to grant Accessibility trust so the
/// media-key tap can be installed. Lifted out of the previous
/// `MediaKeyControlRow` so it can compose cleanly inside a `SettingsCard`.
///
/// Renders two states: untrusted (Grant button) and post-grant flourish
/// (animated checkmark + "Granted" pill). The flourish duration is owned
/// here because the parent only knows about the trust flag, not the
/// transient celebration window.
@MainActor
struct AccessibilityPromptStrip: View {
    @Bindable var accessibility: AccessibilityPermissionService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingGrantedFlourish = false
    @State private var flourishTask: Task<Void, Never>?

    private static let flourishDuration: Duration = .milliseconds(1200)

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: showingGrantedFlourish ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(width: 28, alignment: .center)
                .contentTransition(.symbolEffect(.replace))

            Text(L10n.string(message))
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Spacing.xs)

            if showingGrantedFlourish {
                grantedPill
            } else {
                Button(action: { accessibility.requestAccess() }) {
                    HStack(spacing: 3) {
                        Text(L10n.string("Grant"))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.string("Registers FineTune in the Accessibility list and opens System Settings."))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(
            reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85),
            value: showingGrantedFlourish
        )
        .onChange(of: accessibility.isTrustedCached) { oldValue, newValue in
            if !oldValue, newValue { triggerGrantedFlourish() }
        }
    }

    @ViewBuilder
    private var grantedPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DesignTokens.Colors.vuGreen)
                .frame(width: 5, height: 5)
            Text(L10n.string("Granted"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(DesignTokens.Colors.glassFill))
    }

    private var iconColor: Color {
        showingGrantedFlourish ? DesignTokens.Colors.vuGreen : DesignTokens.Colors.accentPrimary
    }

    private var message: String {
        showingGrantedFlourish
            ? "Access granted — volume keys now control FineTune."
            : "FineTune needs Accessibility to intercept F10 / F11 / F12."
    }

    private func triggerGrantedFlourish() {
        flourishTask?.cancel()
        showingGrantedFlourish = true
        flourishTask = Task { @MainActor in
            try? await Task.sleep(for: Self.flourishDuration)
            guard !Task.isCancelled else { return }
            showingGrantedFlourish = false
        }
    }
}
