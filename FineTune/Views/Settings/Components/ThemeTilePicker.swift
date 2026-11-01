// FineTune/Views/Settings/Components/ThemeTilePicker.swift
import SwiftUI

@MainActor
struct ThemeTilePicker: View {
    @Binding var selection: AppearancePreference

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppearancePreference.allCases) { preference in
                ThemeTile(
                    preference: preference,
                    isSelected: selection == preference,
                    onTap: { selection = preference }
                )
            }
        }
    }
}

// MARK: - Tile

private struct ThemeTile: View {
    let preference: AppearancePreference
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            ThemePreviewMockup(preference: preference)
                .frame(width: 72, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                }

            Text(preference.displayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(preference.displayName))
    }
}

// MARK: - Mockup

private struct ThemePreviewMockup: View {
    let preference: AppearancePreference

    var body: some View {
        switch preference {
        case .system:
            HStack(spacing: 0) {
                MockWindow(scheme: .light)
                MockWindow(scheme: .dark)
            }
        case .light:
            MockWindow(scheme: .light)
        case .dark:
            MockWindow(scheme: .dark)
        }
    }
}

private struct MockWindow: View {
    enum Scheme { case light, dark }

    let scheme: Scheme

    private var bg: Color { scheme == .light ? Color(white: 0.93) : Color(white: 0.11) }
    private var titlebar: Color { scheme == .light ? Color(white: 0.97) : Color(white: 0.18) }
    private var stripe: Color { scheme == .light ? Color(white: 0.72) : Color(white: 0.36) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                titlebar
                HStack(spacing: 2) {
                    Circle().fill(Color(red: 1.00, green: 0.37, blue: 0.36)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 1.00, green: 0.79, blue: 0.27)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 0.24, green: 0.80, blue: 0.34)).frame(width: 3, height: 3)
                }
                .padding(.leading, 4)
            }
            .frame(height: 9)

            VStack(alignment: .leading, spacing: 2.5) {
                Capsule().fill(stripe).frame(width: 18, height: 2)
                Capsule().fill(stripe).frame(width: 26, height: 2)
                Capsule().fill(stripe.opacity(0.7)).frame(width: 14, height: 2)
            }
            .padding(.top, 5)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bg)
        }
    }
}

// MARK: - Popup size tile picker

@MainActor
struct PopupSizeTilePicker: View {
    @Binding var selection: MenuBarPopupSize

    var body: some View {
        HStack(spacing: 12) {
            ForEach(MenuBarPopupSize.allCases) { size in
                PopupSizeTile(
                    size: size,
                    isSelected: selection == size,
                    onTap: { selection = size }
                )
            }
        }
    }
}

private struct PopupSizeTile: View {
    let size: MenuBarPopupSize
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            PopupSizeMockup(size: size)
                .frame(width: 72, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                }

            Text(size.displayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(size.displayName))
    }
}

/// Three rows in every variant so the comparison is honest: only width
/// and breathing room change between size options.
private struct PopupSizeMockup: View {
    let size: MenuBarPopupSize

    private var popupWidth: CGFloat {
        switch size {
        case .compact:     return 52
        case .comfortable: return 62
        case .spacious:    return 70
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .compact:     return 3
        case .comfortable: return 4.5
        case .spacious:    return 6
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .compact:     return 3
        case .comfortable: return 4.5
        case .spacious:    return 6
        }
    }

    private var rowSpacing: CGFloat {
        switch size {
        case .compact:     return 2.5
        case .comfortable: return 4
        case .spacious:    return 5.5
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }
                .frame(width: popupWidth)
                .overlay {
                    VStack(spacing: rowSpacing) {
                        MockDeviceRow()
                        MockDeviceRow()
                        MockDeviceRow()
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .frame(width: popupWidth)
                }
        }
    }
}

private struct MockDeviceRow: View {
    private static let element = Color.secondary.opacity(0.55)
    private static let badge = Color.accentColor.opacity(0.6)

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(Self.badge)
                .frame(width: 3, height: 3)

            Capsule()
                .fill(Self.element)
                .frame(width: 8, height: 2)

            Spacer(minLength: 1)

            Circle()
                .fill(Self.element)
                .frame(width: 2.5, height: 2.5)

            Capsule()
                .fill(Self.element)
                .frame(width: 14, height: 2)

            Capsule()
                .fill(Self.element)
                .frame(width: 4, height: 2)
        }
    }
}

#Preview("Popup Size Tiles") {
    @Previewable @State var dark: MenuBarPopupSize = .comfortable
    @Previewable @State var light: MenuBarPopupSize = .comfortable
    return VStack(spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dark").font(.caption).foregroundStyle(.secondary)
            PopupSizeTilePicker(selection: $dark)
        }
        .padding(16)
        .background(Color(white: 0.10))
        .preferredColorScheme(.dark)

        VStack(alignment: .leading, spacing: 8) {
            Text("Light").font(.caption).foregroundStyle(.secondary)
            PopupSizeTilePicker(selection: $light)
        }
        .padding(16)
        .background(Color(white: 0.96))
        .preferredColorScheme(.light)
    }
    .padding(20)
}
