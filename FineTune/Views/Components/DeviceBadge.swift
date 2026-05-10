// FineTune/Views/Components/DeviceBadge.swift
import SwiftUI
import AppKit

/// Circular tinted badge that replaces the leading radio button on a device row.
/// Selected state uses a gradient of `Color.accentColor` so it follows the user's
/// system accent at full scope. Unselected state uses a monochrome fill from
/// `DesignTokens.Colors.deviceBadgeMonoFill`.
///
/// The badge owns no behavior. The parent row container handles tap-to-set-default
/// via a row-level `TapGesture` so the click target spans the whole row, mirroring
/// the macOS Sound submenu pattern.
struct DeviceBadge: View {
    /// The device's icon image, if available. Falls back to a generic SF symbol.
    let icon: NSImage?
    /// Whether this row is the current default device.
    let isSelected: Bool

    private static let badgeSize: CGFloat = 28
    private static let glyphSize: CGFloat = 20

    var body: some View {
        ZStack {
            // Background fill — accent gradient when selected, mono fill otherwise.
            if isSelected {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.opacity(0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else {
                Circle()
                    .fill(DesignTokens.Colors.deviceBadgeMonoFill)
            }

            // Glyph — device icon when present, generic speaker symbol otherwise.
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: Self.glyphSize, height: Self.glyphSize)
            .foregroundStyle(glyphForeground)
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .accessibilityHidden(true)
    }

    private var glyphForeground: Color {
        isSelected
            ? Color.white
            : DesignTokens.Colors.deviceBadgeMonoForeground
    }
}

// MARK: - Previews

#Preview("DeviceBadge States") {
    HStack(spacing: 16) {
        VStack(spacing: 6) {
            DeviceBadge(icon: nil, isSelected: true)
            Text("Selected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            DeviceBadge(icon: nil, isSelected: false)
            Text("Unselected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .frame(width: 200)
}
