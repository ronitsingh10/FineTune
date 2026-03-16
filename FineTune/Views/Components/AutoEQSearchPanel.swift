// FineTune/Views/Components/AutoEQSearchPanel.swift
import SwiftUI

/// Search panel for selecting AutoEQ headphone correction profiles.
/// Displayed inline within an expanded DeviceRow.
struct AutoEQSearchPanel: View {
    let profileManager: AutoEQProfileManager
    let favoriteIDs: Set<String>
    let selectedProfileID: String?
    let onSelect: (AutoEQProfile?) -> Void
    let onDismiss: () -> Void
    let onImport: () -> Void
    let onToggleFavorite: (String) -> Void
    let importErrorMessage: String?

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var hoveredID: String?
    @State private var starHoveredID: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var highlightedIndex: Int?
    @State private var cachedSearchResult = AutoEQSearchResult(entries: [], totalCount: 0)
    @State private var loadingProfileID: String?
    @State private var fetchError: String?
    @FocusState private var isSearchFocused: Bool

    private let maxVisibleItems = 6
    private let itemHeight: CGFloat = 28
    private var listHeight: CGFloat { CGFloat(maxVisibleItems) * itemHeight }

    // MARK: - Navigable Items

    /// Unified list of all selectable rows for keyboard navigation.
    private enum NavigableItem: Equatable {
        case noCorrection
        case selectedProfile(String)
        case searchResult(String)
        case favorite(String)

        var profileID: String? {
            switch self {
            case .noCorrection: return nil
            case .selectedProfile(let id), .searchResult(let id), .favorite(let id): return id
            }
        }

        var itemID: String {
            switch self {
            case .noCorrection: return "_none"
            case .selectedProfile(let id): return "selected_\(id)"
            case .searchResult(let id): return "result_\(id)"
            case .favorite(let id): return "fav_\(id)"
            }
        }
    }

    private var navigableItems: [NavigableItem] {
        var items: [NavigableItem] = [.noCorrection]

        if let selectedID = selectedProfileID,
           profileManager.profile(for: selectedID) != nil {
            items.append(.selectedProfile(selectedID))
        }

        if !debouncedQuery.isEmpty {
            for entry in results {
                if entry.id == selectedProfileID { continue }
                items.append(.searchResult(entry.id))
            }
        } else {
            for entry in resolvedFavorites {
                items.append(.favorite(entry.id))
            }
        }

        return items
    }

    // MARK: - Computed Results

    private var results: [AutoEQCatalogEntry] {
        let all = cachedSearchResult.entries
        let (favs, rest) = all.reduce(into: ([AutoEQCatalogEntry](), [AutoEQCatalogEntry]())) { acc, e in
            if favoriteIDs.contains(e.id) { acc.0.append(e) } else { acc.1.append(e) }
        }
        return favs + rest
    }

    /// Resolved favorite entries for empty-search display.
    private var resolvedFavorites: [AutoEQCatalogEntry] {
        let catalog = profileManager.catalogEntries
        return favoriteIDs
            .compactMap { id in catalog.first(where: { $0.id == id }) }
            .filter { $0.id != selectedProfileID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var favoritePrefixCount: Int {
        var count = 0
        for entry in results {
            if favoriteIDs.contains(entry.id) { count += 1 } else { break }
        }
        return count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                TextField("Search headphones...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search headphones")

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            // "None" option to remove correction
            Button {
                onSelect(nil)
                onDismiss()
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(selectedProfileID == nil ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)

                    Text("No correction")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selectedProfileID == nil ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)

                    Spacer()

                    if selectedProfileID == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(height: itemHeight)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(rowHighlight(for: "_none", isHovered: hoveredID == "_none"))
                )
            }
            .buttonStyle(.plain)
            .whenHovered { isHovered in
                hoveredID = isHovered ? "_none" : nil
                if isHovered { highlightedIndex = nil }
            }
            .accessibilityLabel("No correction")
            .accessibilityAddTraits(selectedProfileID == nil ? .isSelected : [])
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .padding(.top, DesignTokens.Spacing.xs)

            // Currently selected profile (always visible when a profile is applied)
            if let selectedID = selectedProfileID,
               let selectedProfile = profileManager.profile(for: selectedID) {
                profileRow(selectedProfile, itemIDPrefix: "selected_")
                    .padding(.horizontal, DesignTokens.Spacing.xs)
            }

            // Results / Favorites / Empty state
            if profileManager.catalogState == .loading && profileManager.catalogEntries.isEmpty {
                // Catalog loading for the first time
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading headphone catalog...")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: listHeight)
            } else if debouncedQuery.isEmpty {
                let favorites = resolvedFavorites
                if favorites.isEmpty {
                    Text("Type to search headphones")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: listHeight)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                Text("FAVORITES")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                                    .tracking(1.0)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, DesignTokens.Spacing.sm)
                                    .padding(.top, DesignTokens.Spacing.xs)

                                ForEach(favorites) { entry in
                                    catalogEntryRow(entry, itemIDPrefix: "fav_")
                                        .id(entry.id)
                                }
                            }
                            .padding(.horizontal, DesignTokens.Spacing.xs)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                        }
                        .frame(height: listHeight)
                        .onChange(of: highlightedIndex) { _, _ in
                            scrollToHighlighted(proxy: proxy)
                        }
                    }
                }
            } else if results.isEmpty {
                Text("No profiles found")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: listHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            let favCount = favoritePrefixCount
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                if index == favCount && favCount > 0 {
                                    Divider()
                                        .padding(.horizontal, DesignTokens.Spacing.sm)
                                        .padding(.vertical, 2)
                                }
                                catalogEntryRow(entry, itemIDPrefix: "result_")
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.xs)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                    .frame(height: listHeight)
                    .onChange(of: highlightedIndex) { _, _ in
                        scrollToHighlighted(proxy: proxy)
                    }
                }

                resultCountLabel
            }

            // Catalog error message
            if case .error(let message) = profileManager.catalogState,
               profileManager.catalogEntries.isEmpty {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(message)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)
            }

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            // Import button
            Button {
                onImport()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                    Text("Import ParametricEQ.txt...")
                        .font(.system(size: 11))
                }
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(height: itemHeight)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hoveredID == "_import" ? Color.white.opacity(0.04) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .whenHovered { hoveredID = $0 ? "_import" : nil }
            .accessibilityLabel("Import custom profile")
            .accessibilityHint("Opens file picker for ParametricEQ.txt files")
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .padding(.bottom, DesignTokens.Spacing.xs)

            // Error messages
            if let errorMessage = fetchError ?? importErrorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.bottom, DesignTokens.Spacing.xs)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: fetchError)
        .animation(.easeInOut(duration: 0.2), value: importErrorMessage)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .onKeyPress(.downArrow) {
            moveHighlight(direction: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveHighlight(direction: -1)
            return .handled
        }
        .onKeyPress(.return) {
            activateHighlighted()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onChange(of: searchText) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                debouncedQuery = newValue
            }
        }
        .onChange(of: debouncedQuery) { _, newQuery in
            highlightedIndex = nil
            cachedSearchResult = profileManager.search(query: newQuery)
        }
        .onAppear { isSearchFocused = true }
    }

    // MARK: - Result Count

    @ViewBuilder
    private var resultCountLabel: some View {
        let total = cachedSearchResult.totalCount
        let shown = cachedSearchResult.entries.count
        if total > shown {
            Text("Showing \(shown) of \(total) results")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DesignTokens.Spacing.xxs)
        } else if total > 0 {
            Text("\(total) results")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DesignTokens.Spacing.xxs)
        }
    }

    // MARK: - Profile Row (for already-loaded profiles like the selected one)

    @ViewBuilder
    private func profileRow(_ profile: AutoEQProfile, itemIDPrefix: String) -> some View {
        let isSelected = profile.id == selectedProfileID
        let isFavorited = favoriteIDs.contains(profile.id)
        let itemID = "\(itemIDPrefix)\(profile.id)"
        let isRowHovered = hoveredID == profile.id
        let isStarHovered = starHoveredID == profile.id
        let isRowHighlighted = isHighlighted(itemID)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                if profile.source == .imported {
                    Text("Imported")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                } else if let measuredBy = profile.measuredBy {
                    Text(measuredBy)
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }

            Spacer()

            starButton(id: profile.id, isFavorited: isFavorited, isVisible: isRowHovered || isRowHighlighted, isStarHovered: isStarHovered)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: itemHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowHighlight(for: itemID, isHovered: isRowHovered))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(profile)
            onDismiss()
        }
        .whenHovered { isHovered in
            hoveredID = isHovered ? profile.id : nil
            if isHovered { highlightedIndex = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Apply this correction profile")
    }

    // MARK: - Catalog Entry Row (lightweight, fetches on tap)

    @ViewBuilder
    private func catalogEntryRow(_ entry: AutoEQCatalogEntry, itemIDPrefix: String) -> some View {
        let isSelected = entry.id == selectedProfileID
        let isFavorited = favoriteIDs.contains(entry.id)
        let itemID = "\(itemIDPrefix)\(entry.id)"
        let isRowHovered = hoveredID == entry.id
        let isStarHovered = starHoveredID == entry.id
        let isRowHighlighted = isHighlighted(itemID)
        let isLoading = loadingProfileID == entry.id

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                Text(entry.measuredBy)
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                starButton(id: entry.id, isFavorited: isFavorited, isVisible: isRowHovered || isRowHighlighted, isStarHovered: isStarHovered)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: itemHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowHighlight(for: itemID, isHovered: isRowHovered))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectCatalogEntry(entry)
        }
        .whenHovered { isHovered in
            hoveredID = isHovered ? entry.id : nil
            if isHovered { highlightedIndex = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Apply this correction profile")
    }

    // MARK: - Star Button

    @ViewBuilder
    private func starButton(id: String, isFavorited: Bool, isVisible: Bool, isStarHovered: Bool) -> some View {
        if isFavorited || isVisible {
            Button {
                onToggleFavorite(id)
            } label: {
                Image(systemName: isFavorited ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(starColor(isFavorited: isFavorited, isStarHovered: isStarHovered))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .scaleEffect(isStarHovered ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { starHoveredID = $0 ? id : nil }
            .animation(DesignTokens.Animation.hover, value: isStarHovered)
            .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")
        }
    }

    // MARK: - Async Selection

    private func selectCatalogEntry(_ entry: AutoEQCatalogEntry) {
        guard loadingProfileID == nil else { return }
        loadingProfileID = entry.id
        fetchError = nil

        Task { @MainActor in
            if let profile = await profileManager.resolveProfile(for: entry) {
                onSelect(profile)
                onDismiss()
            } else {
                fetchError = "Failed to load \(entry.name)"
                // Auto-dismiss error after 3 seconds
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if fetchError != nil { fetchError = nil }
                }
            }
            loadingProfileID = nil
        }
    }

    // MARK: - Keyboard Navigation

    private func moveHighlight(direction: Int) {
        let items = navigableItems
        guard !items.isEmpty else { return }

        if let current = highlightedIndex {
            let newIndex = current + direction
            if newIndex >= 0 && newIndex < items.count {
                highlightedIndex = newIndex
            }
        } else {
            highlightedIndex = direction > 0 ? 0 : items.count - 1
        }
        hoveredID = nil
    }

    private func activateHighlighted() {
        let items = navigableItems
        guard let index = highlightedIndex, index < items.count else { return }

        let item = items[index]
        if let profileID = item.profileID {
            // Check if already loaded
            if let profile = profileManager.profile(for: profileID) {
                onSelect(profile)
                onDismiss()
            } else if let entry = profileManager.catalogEntries.first(where: { $0.id == profileID }) {
                selectCatalogEntry(entry)
            }
        } else {
            onSelect(nil)
            onDismiss()
        }
    }

    private func scrollToHighlighted(proxy: ScrollViewProxy) {
        let items = navigableItems
        guard let index = highlightedIndex, index < items.count else { return }
        if let profileID = items[index].profileID {
            withAnimation(.easeOut(duration: 0.1)) {
                proxy.scrollTo(profileID, anchor: .center)
            }
        }
    }

    // MARK: - Helpers

    private func isHighlighted(_ itemID: String) -> Bool {
        guard let index = highlightedIndex else { return false }
        let items = navigableItems
        guard index < items.count else { return false }
        return items[index].itemID == itemID
    }

    private func rowHighlight(for itemID: String, isHovered: Bool) -> Color {
        (isHovered || isHighlighted(itemID)) ? Color.accentColor.opacity(0.15) : Color.clear
    }

    private func starColor(isFavorited: Bool, isStarHovered: Bool) -> Color {
        if isFavorited {
            return DesignTokens.Colors.interactiveActive
        } else if isStarHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }
}
