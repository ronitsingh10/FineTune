// FineTune/Views/Components/PermissionBannerView.swift
import SwiftUI

struct PermissionBannerView: View {
    let permission: AudioRecordingPermission

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                Text("Audio capture access required")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                if permission.status == .denied {
                    Text("Enable in System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                }

                actionButton
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private var actionButton: some View {
        if permission.status == .denied {
            Button("Open System Settings") {
                openSystemAudioSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button("Grant Access") {
                permission.request()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
