import SwiftUI
import AppKit

struct FXDeviceTab: View {
    let isActive: Bool
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    @Environment(ThemeManager.self) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(DesignTokens.Colors.textTertiary.opacity(0.18))
                .frame(width: 0.5)

            HStack(spacing: 2) {
                Text("FX")
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(isActive ? theme.primaryColor : DesignTokens.Colors.textSecondary)
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? theme.primaryColor.opacity(0.14) : Color.clear)
            )
            .padding(.leading, 6)
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .contentShape(Rectangle())
        .overlay(
            LeftRightClickCapture(onLeftClick: onLeftClick, onRightClick: onRightClick)
        )
        .help("left click to alter device's fx; right click to disable fx for device")
    }
}

private struct LeftRightClickCapture: NSViewRepresentable {
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> ClickCaptureView {
        let v = ClickCaptureView()
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: ClickCaptureView, context: Context) {
        nsView.onLeftClick = onLeftClick
        nsView.onRightClick = onRightClick
    }
}

private final class ClickCaptureView: NSView {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
