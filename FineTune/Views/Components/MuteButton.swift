// FineTune/Views/Components/MuteButton.swift
import SwiftUI

/// A mute button with pulse animation on toggle
/// Shows speaker.wave when unmuted, speaker.slash when muted
struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        BaseMuteButton(
            isMuted: isMuted,
            mutedIcon: "speaker.slash.fill",
            unmutedIcon: "speaker.wave.2.fill",
            mutedHelp: "Unmute",
            unmutedHelp: "Mute",
            action: action
        )
    }
}

/// A mute button for input devices (microphones)
/// Shows mic when unmuted, mic.slash when muted
struct InputMuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        BaseMuteButton(
            isMuted: isMuted,
            mutedIcon: "mic.slash.fill",
            unmutedIcon: "mic.fill",
            mutedHelp: "Unmute microphone",
            unmutedHelp: "Mute microphone",
            action: action
        )
    }
}

// MARK: - Base Implementation

/// Shared mute button implementation with configurable icons
private struct BaseMuteButton: View {
    let isMuted: Bool
    let mutedIcon: String
    let unmutedIcon: String
    let mutedHelp: String
    let unmutedHelp: String
    let action: () -> Void

    @State private var isPulsing = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? mutedIcon : unmutedIcon)
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(buttonColor)
                .scaleEffect(isPulsing ? 1.1 : 1.0)
                .frame(width: 16, alignment: .leading)
                .padding(.horizontal, 4)
                .frame(minHeight: DesignTokens.Dimensions.minTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(MuteButtonPressStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isMuted ? mutedHelp : unmutedHelp)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: isPulsing)
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .onChange(of: isMuted) { _, _ in
            isPulsing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isPulsing = false
            }
        }
    }

    private var buttonColor: Color {
        if isMuted {
            return DesignTokens.Colors.mutedIndicator
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }
}

/// Internal button style for press feedback
private struct MuteButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("Mute Button States") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                MuteButton(isMuted: false) {}
                Text("Unmuted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack {
                MuteButton(isMuted: true) {}
                Text("Muted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Input Mute Button States") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                InputMuteButton(isMuted: false) {}
                Text("Unmuted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack {
                InputMuteButton(isMuted: true) {}
                Text("Muted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Mute Button Interactive") {
    struct InteractivePreview: View {
        @State private var isMuted = false

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    MuteButton(isMuted: isMuted) {
                        isMuted.toggle()
                    }

                    Text(isMuted ? "Muted" : "Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
