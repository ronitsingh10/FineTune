// FineTune/Views/Components/AUPluginPickerMenu.swift
import SwiftUI

struct AUPluginPickerMenu: View {
    let scanner: AUPluginScanner
    let getFavoriteIDs: () -> Set<String>
    let getCrashHistory: () -> Set<String>
    let onPluginSelected: (AUPluginDescriptor) -> Void
    let onToggleFavorite: (String) -> Void

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    @Environment(\.appearancePreference) private var appearancePreference

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                Text("Add Effect")
                    .font(DesignTokens.Typography.pickerText)
            }
            .foregroundStyle(isButtonHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isButtonHovered = $0 }
        .background(
            PopoverHost(
                isPresented: $isExpanded,
                preferredColorScheme: appearancePreference.swiftUIColorScheme,
                nsAppearance: appearancePreference.nsAppearance
            ) {
                AUPluginPickerPopover(
                    scanner: scanner,
                    getFavoriteIDs: getFavoriteIDs,
                    getCrashHistory: getCrashHistory,
                    onPluginSelected: { plugin in
                        onPluginSelected(plugin)
                        isExpanded = false
                    },
                    onToggleFavorite: onToggleFavorite
                )
            }
        )
    }
}

/// @Observable tracking doesn't propagate into NSHostingView inside child
/// NSPanels on macOS. The popover owns a @State copy of favorites,
/// seeded from the source of truth when the popover opens. Toggle actions
/// update both local state (immediate UI) and the parent callback (persistence).
private struct AUPluginPickerPopover: View {
    let scanner: AUPluginScanner
    let initialFavoriteIDs: Set<String>
    let crashHistory: Set<String>
    let onPluginSelected: (AUPluginDescriptor) -> Void
    let onToggleFavorite: (String) -> Void

    @State private var favoriteIDs: Set<String>
    @State private var searchText = ""

    private let popoverWidth: CGFloat = 280

    init(scanner: AUPluginScanner, getFavoriteIDs: () -> Set<String>, getCrashHistory: () -> Set<String>, onPluginSelected: @escaping (AUPluginDescriptor) -> Void, onToggleFavorite: @escaping (String) -> Void) {
        self.scanner = scanner
        let favs = getFavoriteIDs()
        self.initialFavoriteIDs = favs
        self.crashHistory = getCrashHistory()
        self.onPluginSelected = onPluginSelected
        self.onToggleFavorite = onToggleFavorite
        self._favoriteIDs = State(initialValue: favs)
    }

    private var filteredPlugins: [AUPluginDescriptor] {
        if searchText.isEmpty { return scanner.plugins }
        let query = searchText.lowercased()
        return scanner.plugins.filter {
            $0.name.lowercased().contains(query) || $0.manufacturer.lowercased().contains(query)
        }
    }

    var body: some View {
        let favIDs = favoriteIDs
        let crashHistory = crashHistory
        let favorites = filteredPlugins.filter { favIDs.contains($0.id) }
        let nonFavorites = filteredPlugins.filter { !favIDs.contains($0.id) }
        let manufacturers = Dictionary(grouping: nonFavorites, by: \.manufacturer)
            .sorted { $0.key < $1.key }

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .font(.system(size: 12))
                TextField("Search Audio Units…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(DesignTokens.Colors.recessedBackground)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !favorites.isEmpty {
                        sectionHeader("Favorites")
                        ForEach(favorites) { plugin in
                            pluginRow(plugin, isFav: true, crashHistory: crashHistory)
                                .id("fav-\(plugin.id)")
                        }
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(manufacturers, id: \.0) { manufacturer, plugins in
                        sectionHeader(manufacturer)
                        ForEach(plugins) { plugin in
                            pluginRow(plugin, isFav: false, crashHistory: crashHistory)
                                .id("mfr-\(plugin.id)")
                        }
                    }

                    if filteredPlugins.isEmpty {
                        Text("No Audio Units found")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: popoverWidth)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func pluginRow(_ plugin: AUPluginDescriptor, isFav: Bool, crashHistory: Set<String>) -> some View {
        HStack(spacing: 6) {
            Button {
                if favoriteIDs.contains(plugin.id) {
                    favoriteIDs.remove(plugin.id)
                } else {
                    favoriteIDs.insert(plugin.id)
                }
                onToggleFavorite(plugin.id)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(isFav ? .yellow : DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            Button {
                onPluginSelected(plugin)
            } label: {
                HStack(spacing: 4) {
                    Text(plugin.name)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)

                    if crashHistory.contains(plugin.id) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("This plugin may have caused a crash")
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}
