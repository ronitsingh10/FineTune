import SwiftUI

struct ParametricPresetPicker: View {
    @ObservedObject var presetManager = PresetManager.shared
    @Binding var isImportSheetPresented: Bool
    var selectedPreset: CustomEQPreset?
    let onApplyPreset: (CustomEQPreset) -> Void
    let onDeletePreset: (CustomEQPreset) -> Void
    
    // Wrapper for menu items
    enum PickerItem: Identifiable, Hashable {
        case preset(CustomEQPreset)
        case importAction
        
        var id: String {
            switch self {
            case .preset(let p): return p.id.uuidString
            case .importAction: return "import-action"
            }
        }
        
        static func == (lhs: PickerItem, rhs: PickerItem) -> Bool {
            lhs.id == rhs.id
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
    
    enum Section: String, CaseIterable, Identifiable {
        case presets = "Presets"
        case actions = "Options"
        
        var id: String { rawValue }
    }
    
    var body: some View {
        GroupedDropdownMenu(
            sections: Section.allCases,
            itemsForSection: { section in
                switch section {
                case .presets:
                    return presetManager.presets.map { PickerItem.preset($0) }
                case .actions:
                    return [.importAction]
                }
            },
            sectionTitle: { $0.rawValue },
            selectedItem: nil,
            maxHeight: 300,
            width: 140,
            popoverWidth: 220,
            onSelect: { item in
                switch item {
                case .preset(let p):
                    onApplyPreset(p)
                case .importAction:
                    isImportSheetPresented = true
                }
            }
        ) { _ in // Label
            Text(selectedPreset?.name ?? "Custom Presets")
                .foregroundColor(selectedPreset != nil ? .primary : DesignTokens.Colors.textSecondary)
        } itemContent: { item, isSelected in
            HStack {
                switch item {
                case .preset(let p):
                    Text(p.name)
                        .lineLimit(1)
                    Spacer()
                    // Delete button
                    Button(action: {
                        onDeletePreset(p)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete preset")
                case .importAction:
                    Label("Import Preset...", systemImage: "square.and.arrow.down")
                        .foregroundColor(.accentColor)
                    Spacer()
                }
            }
        }
        // Force re-render when presets change (e.g., after deletion)
        .id(presetManager.presets.map(\.id))
    }
}
