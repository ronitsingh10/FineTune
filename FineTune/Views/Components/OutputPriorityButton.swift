import SwiftUI

/// Compact shortcut to the same output policy used in Audio settings.
struct OutputPriorityButton: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Button("Output Device Priority", systemImage: "arrow.up.arrow.down") {
            isEnabled.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: isEnabled ? .semibold : .regular))
        .foregroundStyle(isEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.interactiveDefault)
        .frame(width: 20, height: 20)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(isEnabled ? DesignTokens.Colors.accentPrimary.opacity(0.12) : .clear)
        }
        .contentShape(Rectangle())
        .fixedSize()
        .help(isEnabled
            ? "Output priority is on: use FineTune's device order. Click to follow macOS."
            : "Output priority is off: follow macOS. Click to use FineTune's device order.")
        .accessibilityValue(isEnabled ? "On, FineTune device order" : "Off, follows macOS")
    }
}
