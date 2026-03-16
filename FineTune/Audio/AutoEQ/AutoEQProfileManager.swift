// FineTune/Audio/AutoEQ/AutoEQProfileManager.swift
import Foundation
import os

/// Search result from `AutoEQProfileManager.search()`.
struct AutoEQSearchResult {
    let entries: [AutoEQCatalogEntry]
    let totalCount: Int
}

/// Manages the catalog of AutoEQ headphone correction profiles.
/// Search operates on lightweight catalog entries; full profiles are resolved on demand.
@Observable
@MainActor
final class AutoEQProfileManager {
    /// Fully-loaded profiles (imported + previously fetched).
    private(set) var profiles: [String: AutoEQProfile] = [:]

    private let fetcher: AutoEQFetcher
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AutoEQProfileManager")
    private let loader: AutoEQProfileLoader

    /// Pre-sorted catalog entries for fast search.
    private var sortedEntries: [AutoEQCatalogEntry] = []

    /// Normalized names for fuzzy search (parallel array with sortedEntries).
    private var normalizedNames: [String] = []

    init(loader: AutoEQProfileLoader = AutoEQProfileLoader(), fetcher: AutoEQFetcher? = nil) {
        self.loader = loader
        self.fetcher = fetcher ?? AutoEQFetcher()

        // Imported profiles are small — load synchronously
        let imported = loader.loadImportedProfiles()
        for profile in imported {
            profiles[profile.id] = profile
        }

        // Load catalog from cache/GitHub
        Task { @MainActor in
            await self.fetcher.loadCatalog()
            self.rebuildSearchIndex()
        }
    }

    // MARK: - Catalog State (forwarded from fetcher)

    var catalogState: AutoEQFetcher.FetchState { fetcher.catalogState }
    var catalogEntries: [AutoEQCatalogEntry] { fetcher.catalog }

    func catalogEntry(for id: String) -> AutoEQCatalogEntry? {
        fetcher.catalog.first(where: { $0.id == id })
    }

    // MARK: - Import / Delete

    /// Import a ParametricEQ.txt file. Copies to app support and adds to catalog.
    func importProfile(from url: URL, name: String) -> AutoEQProfile? {
        guard let profile = loader.importProfile(from: url, name: name) else { return nil }
        profiles[profile.id] = profile
        rebuildSearchIndex()
        return profile
    }

    /// Delete an imported profile from disk and catalog.
    func deleteImportedProfile(id: String) {
        guard let profile = profiles[id], profile.source == .imported else { return }
        profiles.removeValue(forKey: id)
        loader.deleteProfileFiles(id: id)
        rebuildSearchIndex()
        logger.info("Deleted imported profile: \(profile.name)")
    }

    // MARK: - Profile Resolution

    /// Resolve a profile by ID: memory → cache → network.
    func resolveProfile(for id: String) async -> AutoEQProfile? {
        // Already loaded (imported or previously fetched)
        if let existing = profiles[id] { return existing }

        // Find catalog entry for this ID
        guard let entry = fetcher.catalog.first(where: { $0.id == id }) else { return nil }

        do {
            let profile = try await fetcher.fetchProfile(for: entry)
            profiles[id] = profile
            return profile
        } catch {
            logger.error("Failed to resolve profile \(id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolve a profile from a catalog entry.
    func resolveProfile(for entry: AutoEQCatalogEntry) async -> AutoEQProfile? {
        if let existing = profiles[entry.id] { return existing }

        do {
            let profile = try await fetcher.fetchProfile(for: entry)
            profiles[entry.id] = profile
            return profile
        } catch {
            logger.error("Failed to fetch profile \(entry.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Look up a profile by ID (only returns already-loaded profiles).
    func profile(for id: String) -> AutoEQProfile? {
        profiles[id]
    }

    // MARK: - Search

    /// Rebuild the search index from fetcher catalog + imported profiles.
    private func rebuildSearchIndex() {
        // Catalog entries from GitHub
        var entries = fetcher.catalog

        // Add imported profiles as pseudo-catalog entries
        for profile in profiles.values where profile.source == .imported {
            let entry = AutoEQCatalogEntry(
                id: profile.id,
                name: profile.name,
                measuredBy: "Imported",
                relativePath: ""
            )
            entries.append(entry)
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        sortedEntries = entries
        normalizedNames = entries.map { Self.normalize($0.name) }
    }

    /// Fuzzy search across catalog entry names with relevance ranking.
    func search(query: String, limit: Int = 50) -> AutoEQSearchResult {
        guard !query.isEmpty else { return AutoEQSearchResult(entries: [], totalCount: 0) }

        let loweredQuery = query.lowercased()
        let normalizedQuery = Self.normalize(query)

        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(200)

        for i in 0..<sortedEntries.count {
            let loweredName = sortedEntries[i].name.lowercased()
            let normalizedName = normalizedNames[i]

            let score = Self.matchScore(
                loweredQuery: loweredQuery,
                normalizedQuery: normalizedQuery,
                loweredName: loweredName,
                normalizedName: normalizedName
            )

            if score > 0 {
                scored.append((index: i, score: score))
            }
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return sortedEntries[$0.index].name < sortedEntries[$1.index].name
        }

        let totalCount = scored.count
        let limitedResults = scored.prefix(limit).map { sortedEntries[$0.index] }

        return AutoEQSearchResult(entries: Array(limitedResults), totalCount: totalCount)
    }

    // MARK: - Scoring

    private static func matchScore(
        loweredQuery: String,
        normalizedQuery: String,
        loweredName: String,
        normalizedName: String
    ) -> Int {
        // Tier 1: Exact substring in original name (case-insensitive)
        if loweredName.contains(loweredQuery) {
            var score = 100
            if loweredName.hasPrefix(loweredQuery) { score += 50 }
            if loweredName == loweredQuery { score += 100 }
            score += max(0, 50 - loweredName.count)
            return score
        }

        // Tier 2: Normalized substring (space/punctuation tolerance)
        if !normalizedQuery.isEmpty && normalizedName.contains(normalizedQuery) {
            var score = 50
            if normalizedName.hasPrefix(normalizedQuery) { score += 25 }
            score += max(0, 25 - normalizedName.count)
            return score
        }

        // Tier 3: Token-based fuzzy match
        let queryTokens = loweredQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !queryTokens.isEmpty else { return 0 }

        var totalTokenScore = 0
        for token in queryTokens {
            let tokenScore = bestTokenMatch(token: token, in: loweredName)
            if tokenScore == 0 { return 0 }
            totalTokenScore += tokenScore
        }

        return min(49, totalTokenScore / queryTokens.count)
    }

    private static func bestTokenMatch(token: String, in name: String) -> Int {
        if name.contains(token) { return 40 }

        let nameTokens = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        let maxAllowedDistance = token.count <= 4 ? 1 : 2

        var bestScore = 0
        for nameToken in nameTokens {
            let distance = editDistance(token, nameToken.lowercased())
            if distance <= maxAllowedDistance {
                let score = max(1, 30 - distance * 10)
                bestScore = max(bestScore, score)
            }
        }
        return bestScore
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }
        if abs(m - n) > 2 { return max(m, n) }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j - 1], prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    // MARK: - Normalization

    private static func normalize(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string.unicodeScalars {
            if CharacterSet.alphanumerics.contains(char) {
                result.append(Character(char))
            }
        }
        return result.lowercased()
    }
}
