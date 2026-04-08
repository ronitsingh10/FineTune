// FineTune/Views/Components/EQPresetPicker.swift
import SwiftUI

// MARK: - Unified Picker Types

/// Sections for the EQ preset picker — "My Presets" at top, then built-in categories.
enum EQPickerSection: Identifiable, Hashable {
    case myPresets
    case builtIn(EQPreset.Category)

    var id: String {
        switch self {
        case .myPresets: return "my-presets"
        case .builtIn(let cat): return cat.rawValue
        }
    }

    var title: String {
        switch self {
        case .myPresets: return "My Presets"
        case .builtIn(let cat): return cat.rawValue
        }
    }
}

/// A single item in the picker — wraps either a built-in or user preset.
struct EQPickerItem: Identifiable, Hashable {
    let id: String
    let name: String
    let builtInPreset: EQPreset?
    let userPresetID: UUID?

    init(builtIn preset: EQPreset) {
        self.id = "builtin-\(preset.id)"
        self.name = preset.name
        self.builtInPreset = preset
        self.userPresetID = nil
    }

    init(user preset: UserEQPreset) {
        self.id = "user-\(preset.id.uuidString)"
        self.name = preset.name
        self.builtInPreset = nil
        self.userPresetID = preset.id
    }

    var isUserPreset: Bool { userPresetID != nil }

    static func == (lhs: EQPickerItem, rhs: EQPickerItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - EQ Preset Picker

struct EQPresetPicker: View {
    let selectedItem: EQPickerItem?
    let userPresets: [UserEQPreset]
    let onBuiltInSelected: (EQPreset) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    private var sections: [EQPickerSection] {
        var result: [EQPickerSection] = []
        if !userPresets.isEmpty {
            result.append(.myPresets)
        }
        result.append(contentsOf: EQPreset.Category.allCases.map { .builtIn($0) })
        return result
    }

    private func items(for section: EQPickerSection) -> [EQPickerItem] {
        switch section {
        case .myPresets:
            return userPresets.map { EQPickerItem(user: $0) }
        case .builtIn(let category):
            return EQPreset.presets(for: category).map { EQPickerItem(builtIn: $0) }
        }
    }

    private func handleSelect(_ item: EQPickerItem) {
        if let preset = item.builtInPreset {
            onBuiltInSelected(preset)
        } else if let userID = item.userPresetID,
                  let userPreset = userPresets.first(where: { $0.id == userID }) {
            onUserPresetSelected(userPreset)
        }
    }

    var body: some View {
        GroupedDropdownMenu(
            sections: sections,
            itemsForSection: { items(for: $0) },
            sectionTitle: { $0.title },
            selectedItem: selectedItem,
            maxHeight: 320,
            width: 100,
            popoverWidth: 170,
            onSelect: handleSelect
        ) { selected in
            Text(selected?.name ?? "Custom")
        } itemContent: { item, isSelected in
            if item.isUserPreset {
                UserPresetItemView(
                    item: item,
                    isSelected: isSelected,
                    onDelete: onDeleteUserPreset
                )
            } else {
                BuiltInPresetItemView(item: item, isSelected: isSelected)
            }
        }
    }
}

// MARK: - Built-In Preset Item

private struct BuiltInPresetItemView: View {
    let item: EQPickerItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(item.name)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.xs)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - User Preset Item (with hover-revealed delete)

private struct UserPresetItemView: View {
    let item: EQPickerItem
    let isSelected: Bool
    let onDelete: (UUID) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(item.name)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.xs)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            if let userID = item.userPresetID {
                Button {
                    onDelete(userID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isHovered ? DesignTokens.Colors.interactiveHover : .clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete preset \(item.name)")
                .help("Delete preset")
            }
        }
        .whenHovered { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}

// MARK: - Previews

#Preview("With User Presets") {
    let sampleUser = [
        UserEQPreset(name: "My Bass Boost", settings: EQSettings(bandGains: [6, 5, 4, 0, 0, 0, 0, 0, 0, 0])),
        UserEQPreset(name: "Studio Monitor", settings: EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 1, 2, 2, 2]))
    ]
    VStack(spacing: 20) {
        EQPresetPicker(
            selectedItem: EQPickerItem(builtIn: .rock),
            userPresets: sampleUser,
            onBuiltInSelected: { _ in },
            onUserPresetSelected: { _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
        EQPresetPicker(
            selectedItem: nil,
            userPresets: [],
            onBuiltInSelected: { _ in },
            onUserPresetSelected: { _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
    }
    .padding()
    .background(Color.black)
}
