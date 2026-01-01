// FineTune/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if audioEngine.apps.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "speaker.slash")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No apps playing audio")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                ForEach(audioEngine.apps) { app in
                    AppVolumeRowView(
                        app: app,
                        volume: audioEngine.getVolume(for: app),
                        onVolumeChange: { volume in
                            audioEngine.setVolume(for: app, to: volume)
                        }
                    )
                }
            }

            Divider()

            Button("Quit FineTune") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding()
        .frame(width: 320)
    }
}
