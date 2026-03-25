import AppKit
import SwiftUI

@MainActor
final class VolumeHUDController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var hostingView: NSHostingView<AnyView>?

    func show(volume: Float, isMuted: Bool) {
        dismissTask?.cancel()

        let content = AnyView(
            VolumeHUDContentView(volume: volume, isMuted: isMuted)
                .environment(\.colorScheme, .dark)
        )

        if let existingPanel = panel {
            hostingView?.rootView = content
            existingPanel.alphaValue = 1
            existingPanel.orderFrontRegardless()
        } else {
            let hudHostingView = NSHostingView(rootView: content)
            hostingView = hudHostingView

            let newPanel = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 280, height: 72),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            newPanel.level = .floating
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.ignoresMouseEvents = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            newPanel.contentView = hudHostingView
            panel = newPanel
        }

        positionNearBottom()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.fadeOut()
        }
    }

    private func positionNearBottom() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let hudSize = panel.frame.size
        let x = screenFrame.midX - hudSize.width / 2
        let y = screenFrame.minY + 80
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func fadeOut() async {
        await MainActor.run {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.panel?.animator().alphaValue = 0
            }
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        await MainActor.run {
            panel?.orderOut(nil)
        }
    }
}

private struct VolumeHUDContentView: View {
    let volume: Float
    let isMuted: Bool

    private var iconName: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.fill" }
        if volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                    Capsule()
                        .fill(.white)
                        .frame(width: geo.size.width * CGFloat(isMuted ? 0 : volume))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 280, height: 72)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
        }
        .padding(8)
    }
}
