// FineTune/Views/Components/AutoEQSearchPanel.swift
import SwiftUI

/// Search panel for selecting AutoEQ headphone correction profiles.
/// Two-zone layout: Status Zone (profile card or empty state)
/// above Browse Zone (search + favorites/results + import).
struct AutoEQSearchPanel: View {
    let profileManager: AutoEQProfileManager
    let favoriteIDs: Set<String>
    let selectedProfileID: String?
    let onSelect: (AutoEQProfile?) -> Void
    let onDismiss: () -> Void
    let onImport: () -> Void
    let onToggleFavorite: (String) -> Void
    let importErrorMessage: String?
    var isCorrectionEnabled: Bool = false
    var onCorrectionToggle: ((Bool) -> Void)?
    var preampEnabled: Bool = true
    var onPreampToggle: (() -> Void)?

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

    /// Selectable rows for keyboard navigation (browse zone only).
    private enum NavigableItem: Equatable {
        case searchResult(String)
        case favorite(String)

        var profileID: String {
            switch self {
            case .searchResult(let id), .favorite(let id): return id
            }
        }

        var itemID: String {
            switch self {
            case .searchResult(let id): return "result_\(id)"
            case .favorite(let id): return "fav_\(id)"
            }
        }
    }

    private var navigableItems: [NavigableItem] {
        if !debouncedQuery.isEmpty {
            return results
                .filter { $0.id != selectedProfileID }
                .map { .searchResult($0.id) }
        } else {
            return resolvedFavorites.map { .favorite($0.id) }
        }
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

    /// Resolved display info for the status card.
    private var cardProfileInfo: (name: String, source: String?)? {
        guard let selectedID = selectedProfileID else { return nil }
        if let profile = profileManager.profile(for: selectedID) {
            let source = profile.source == .imported ? "Imported" : profile.measuredBy
            return (profile.name, source)
        } else if let entry = profileManager.catalogEntry(for: selectedID) {
            return (entry.name, entry.measuredBy)
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            statusZone

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            searchField

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            browseZone

            catalogError

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            importButton

            errorMessages
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

    // MARK: - Status Zone

    @ViewBuilder
    private var statusZone: some View {
        if let selectedID = selectedProfileID, let info = cardProfileInfo {
            statusCard(id: selectedID, name: info.name, source: info.source)
                .transition(.opacity)
        } else if selectedProfileID != nil {
            statusCardLoading
                .transition(.opacity)
        } else {
            emptyStateView
                .transition(.opacity)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 20))
                .foregroundStyle(DesignTokens.Colors.autoEQEmptyIcon)

            Text("No correction active")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Text("Search or pick a favorite below")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(
                    DesignTokens.Colors.autoEQEmptyBorder,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
        )
        .padding(DesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("No correction active. Search or pick a favorite below."))
    }

    // MARK: - Loading Placeholder

    private var statusCardLoading: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading profile...")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.autoEQEmptyBorder, lineWidth: 1)
        )
        .padding(DesignTokens.Spacing.sm)
    }

    // MARK: - Status Section (flat, no card container)

    @ViewBuilder
    private func statusCard(id: String, name: String, source: String?) -> some View {
        let isFavorited = favoriteIDs.contains(id)
        let isStarHovered = starHoveredID == id

        VStack(spacing: DesignTokens.Spacing.sm) {
            // Profile info + action buttons
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(name)
                        .font(DesignTokens.Typography.cardProfileName)
                        .foregroundStyle(
                            isCorrectionEnabled
                                ? DesignTokens.Colors.textPrimary
                                : DesignTokens.Colors.textSecondary
                        )
                        .lineLimit(1)

                    if let source {
                        Text(source)
                            .font(DesignTokens.Typography.cardSource)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    // Star button (always visible)
                    Button {
                        onToggleFavorite(id)
                    } label: {
                        Image(systemName: isFavorited ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(
                                starColor(isFavorited: isFavorited, isStarHovered: isStarHovered)
                            )
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                            .scaleEffect(isStarHovered ? 1.1 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .onHover { starHoveredID = $0 ? id : nil }
                    .animation(DesignTokens.Animation.hover, value: isStarHovered)
                    .accessibilityLabel(L10n.string(isFavorited ? "Remove from favorites" : "Add to favorites"))

                    // Remove button
                    Button {
                        onSelect(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(
                                hoveredID == "_remove"
                                    ? DesignTokens.Colors.textSecondary
                                    : DesignTokens.Colors.textTertiary
                            )
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .whenHovered { hoveredID = $0 ? "_remove" : nil }
                    .accessibilityLabel(L10n.string("Remove correction profile"))
                    .accessibilityHint(L10n.string("Returns to no correction state"))
                }
            }

            // Mini toggle switches
            HStack(spacing: 10) {
                miniToggle(
                    label: "Correction",
                    isOn: isCorrectionEnabled
                ) { onCorrectionToggle?(!isCorrectionEnabled) }

                miniToggle(
                    label: "Preamp",
                    isOn: preampEnabled
                ) { onPreampToggle?() }

                Spacer()
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .animation(.easeInOut(duration: 0.15), value: isCorrectionEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("%@ correction profile", name))
    }

    // MARK: - Mini Toggle

    private func miniToggle(
        label: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(L10n.string(label))
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.autoEQToggleLabel)

            Toggle(
                label,
                isOn: Binding(get: { isOn }, set: { _ in action() })
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .scaleEffect(0.65)
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string(label))
        .accessibilityValue(L10n.string(isOn ? "On" : "Off"))
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            TextField("Search headphones...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .focused($isSearchFocused)
                .accessibilityLabel(L10n.string("Search headphones"))

            if !searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    searchText = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    // MARK: - Browse Zone

    @ViewBuilder
    private var browseZone: some View {
        if profileManager.catalogState == .loading && profileManager.catalogEntries.isEmpty {
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
    }

    // MARK: - Catalog Error

    @ViewBuilder
    private var catalogError: some View {
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
    }

    // MARK: - Import Button

    private var importButton: some View {
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
                    .fill(hoveredID == "_import" ? DesignTokens.Colors.hoverSurface : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .whenHovered { hoveredID = $0 ? "_import" : nil }
        .accessibilityLabel(L10n.string("Import custom profile"))
        .accessibilityHint(L10n.string("Opens file picker for ParametricEQ.txt files"))
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    // MARK: - Error Messages

    @ViewBuilder
    private var errorMessages: some View {
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

    // MARK: - Catalog Entry Row

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
                starButton(
                    id: entry.id,
                    isFavorited: isFavorited,
                    isVisible: isRowHovered || isRowHighlighted,
                    isStarHovered: isStarHovered
                )

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
        .accessibilityAddTraits(.isButton)
        .whenHovered { isHovered in
            hoveredID = isHovered ? entry.id : nil
            if isHovered { highlightedIndex = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(L10n.string("Apply this correction profile"))
    }

    // MARK: - Star Button (browse zone rows)

    @ViewBuilder
    private func starButton(
        id: String,
        isFavorited: Bool,
        isVisible: Bool,
        isStarHovered: Bool
    ) -> some View {
        if isFavorited || isVisible {
            Button {
                onToggleFavorite(id)
            } label: {
                Image(systemName: isFavorited ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        starColor(isFavorited: isFavorited, isStarHovered: isStarHovered)
                    )
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .scaleEffect(isStarHovered ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { starHoveredID = $0 ? id : nil }
            .animation(DesignTokens.Animation.hover, value: isStarHovered)
            .accessibilityLabel(L10n.string(isFavorited ? "Remove from favorites" : "Add to favorites"))
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
                fetchError = L10n.format("Failed to load %@", entry.name)
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

        let profileID = items[index].profileID
        if let profile = profileManager.profile(for: profileID) {
            onSelect(profile)
            onDismiss()
        } else if let entry = profileManager.catalogEntries.first(where: { $0.id == profileID }) {
            selectCatalogEntry(entry)
        }
    }

    private func scrollToHighlighted(proxy: ScrollViewProxy) {
        let items = navigableItems
        guard let index = highlightedIndex, index < items.count else { return }
        let profileID = items[index].profileID
        withAnimation(.easeOut(duration: 0.1)) {
            proxy.scrollTo(profileID, anchor: .center)
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
