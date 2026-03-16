// FineTune/Audio/AutoEQ/AutoEQFetcher.swift
import Foundation
import os

/// Fetches AutoEQ profiles on-demand from the AutoEQ GitHub repository.
/// Caches the catalog index and individual profiles to disk.
@Observable
@MainActor
final class AutoEQFetcher {
    enum FetchState: Equatable {
        case idle, loading, loaded, error(String)
    }

    private(set) var catalogState: FetchState = .idle
    private(set) var catalog: [AutoEQCatalogEntry] = []

    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AutoEQFetcher")

    // MARK: - URLs

    private static let indexURL = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md")!
    private static let profileBaseURL = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"

    // MARK: - Cache Paths

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FineTune")
    }

    private static var catalogCacheURL: URL {
        cacheDirectory.appendingPathComponent("autoeq-catalog.json")
    }

    private static var fetchedProfilesDirectory: URL {
        cacheDirectory.appendingPathComponent("AutoEQ").appendingPathComponent("fetched")
    }

    /// Source priority for deduplication (lower index = preferred).
    private static let sourcePriority = [
        "oratory1990", "crinacle", "Rtings", "Innerfidelity", "Super Review", "Headphone.com Legacy"
    ]

    /// Catalog cache TTL: 7 days.
    private static let catalogTTL: TimeInterval = 7 * 24 * 3600

    // MARK: - Catalog

    /// Load catalog from cache first, then refresh from GitHub in the background.
    func loadCatalog() async {
        // Try cached catalog first
        if let cached = loadCatalogFromCache() {
            catalog = cached
            catalogState = .loaded
            logger.info("Loaded \(cached.count) catalog entries from cache")

            // Refresh in background if cache is stale
            if isCatalogCacheStale() {
                Task { @MainActor in
                    await refreshCatalogFromGitHub()
                }
            }
            return
        }

        // No cache — must fetch
        await refreshCatalogFromGitHub()
    }

    /// Fetch the catalog from GitHub INDEX.md and cache it.
    func refreshCatalogFromGitHub() async {
        catalogState = .loading
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.indexURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                catalogState = .error("Failed to fetch catalog")
                logger.error("Catalog fetch returned non-200 status")
                return
            }

            guard let text = String(data: data, encoding: .utf8) else {
                catalogState = .error("Invalid catalog data")
                return
            }

            let entries = Self.parseIndexMarkdown(text)

            catalog = entries
            catalogState = .loaded
            logger.info("Fetched \(entries.count) catalog entries from GitHub")

            // Cache to disk
            saveCatalogToCache(entries)
        } catch {
            // Keep existing cached catalog if we have one
            if catalog.isEmpty {
                catalogState = .error("Network error: \(error.localizedDescription)")
            }
            logger.error("Catalog fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Profile Fetching

    /// Fetch a single profile. Checks local cache first, then GitHub.
    func fetchProfile(for entry: AutoEQCatalogEntry) async throws -> AutoEQProfile {
        // Check local cache
        if let cached = loadCachedProfile(id: entry.id, name: entry.name, measuredBy: entry.measuredBy) {
            return cached
        }

        // Construct URL: relativePath is already URL-decoded from parsing,
        // but the filename needs percent-encoding for spaces/special chars
        let decodedPath = entry.relativePath
        let lastComponent = decodedPath.components(separatedBy: "/").last ?? entry.name
        let fileName = "\(lastComponent) ParametricEQ.txt"

        guard let encodedPath = decodedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(Self.profileBaseURL)\(encodedPath)/\(encodedFileName)") else {
            throw FetchError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FetchError.profileNotFound(entry.name)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidData
        }

        guard let profile = AutoEQParser.parse(
            text: text, name: entry.name, source: .fetched, id: entry.id
        ) else {
            throw FetchError.parseFailed(entry.name)
        }

        // Attach measuredBy from catalog entry
        let enrichedProfile = AutoEQProfile(
            id: profile.id,
            name: profile.name,
            source: profile.source,
            preampDB: profile.preampDB,
            filters: profile.filters,
            measuredBy: entry.measuredBy,
            optimizedSampleRate: 48000
        )

        // Cache the .txt to disk for offline use
        cacheProfileText(text, id: entry.id)

        logger.info("Fetched profile: \(entry.name)")
        return enrichedProfile
    }

    // MARK: - Cache Management

    /// Check if a profile is already cached locally.
    func hasCachedProfile(id: String) -> Bool {
        let file = Self.fetchedProfilesDirectory.appendingPathComponent("\(id).txt")
        return FileManager.default.fileExists(atPath: file.path)
    }

    // MARK: - INDEX.md Parsing

    /// Parse INDEX.md markdown into catalog entries with deduplication.
    /// Keeps the highest-priority source for each headphone name.
    static func parseIndexMarkdown(_ text: String) -> [AutoEQCatalogEntry] {
        // Pattern: - [Name](./relative/path) by Source
        // or:      - [Name](./relative/path) by Source on Rig
        let lines = text.components(separatedBy: .newlines)

        // name → (entry, priority)
        var bestByName: [String: (entry: AutoEQCatalogEntry, priority: Int)] = [:]
        bestByName.reserveCapacity(lines.count)

        for line in lines {
            guard let entry = parseCatalogLine(line) else { continue }

            let normalizedName = entry.name.lowercased()
            let priority = sourcePriorityIndex(entry.measuredBy)

            if let existing = bestByName[normalizedName] {
                if priority < existing.priority {
                    bestByName[normalizedName] = (entry, priority)
                }
            } else {
                bestByName[normalizedName] = (entry, priority)
            }
        }

        return bestByName.values
            .map(\.entry)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parse a single INDEX.md line into a catalog entry.
    /// Handles headphone names with parentheses (e.g., "64 Audio A12t (m15 Apex module)")
    /// by using `](` and `) by ` as structural boundaries instead of bare `(` / `)`.
    private static func parseCatalogLine(_ line: String) -> AutoEQCatalogEntry? {
        // Format: "- [Name](./relative/path%20encoded) by Source on Rig"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- [") else { return nil }

        // Find "](", the boundary between name and URL in markdown link syntax.
        // This avoids confusion with () inside headphone names.
        guard let linkBoundary = trimmed.range(of: "](") else { return nil }

        // Name is between "- [" and "]("
        let nameStart = trimmed.index(trimmed.startIndex, offsetBy: 2) // skip "- "
        let name = String(trimmed[trimmed.index(after: nameStart)..<linkBoundary.lowerBound])
        guard !name.isEmpty else { return nil }

        // Find ") by " searching backwards — the URL itself may contain () in the path
        // (e.g., "(m15%20Apex%20module)"), so the LAST ") by " marks the true URL end.
        guard let urlEnd = trimmed.range(of: ") by ", options: .backwards) else { return nil }

        // URL is between "](" and ") by "
        var rawPath = String(trimmed[linkBoundary.upperBound..<urlEnd.lowerBound])

        // Strip leading "./" prefix
        if rawPath.hasPrefix("./") {
            rawPath = String(rawPath.dropFirst(2))
        }

        // URL-decode the path (spaces are %20 in INDEX.md)
        let relativePath = rawPath.removingPercentEncoding ?? rawPath

        // Source (and optional rig) is everything after ") by "
        let sourceAndRig = String(trimmed[urlEnd.upperBound...])

        // Source is everything before " on " (if present)
        let measuredBy: String
        if let onRange = sourceAndRig.range(of: " on ") {
            measuredBy = String(sourceAndRig[..<onRange.lowerBound])
        } else {
            measuredBy = sourceAndRig.trimmingCharacters(in: .whitespaces)
        }
        guard !measuredBy.isEmpty else { return nil }

        let id = slugify(name)
        return AutoEQCatalogEntry(id: id, name: name, measuredBy: measuredBy, relativePath: relativePath)
    }

    private static func sourcePriorityIndex(_ source: String) -> Int {
        sourcePriority.firstIndex(of: source) ?? sourcePriority.count
    }

    private static func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: - Catalog Cache

    private func loadCatalogFromCache() -> [AutoEQCatalogEntry]? {
        let url = Self.catalogCacheURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([AutoEQCatalogEntry].self, from: data)
        } catch {
            logger.warning("Failed to load catalog cache: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveCatalogToCache(_ entries: [AutoEQCatalogEntry]) {
        let url = Self.catalogCacheURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("Failed to save catalog cache: \(error.localizedDescription)")
        }
    }

    private func isCatalogCacheStale() -> Bool {
        let url = Self.catalogCacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            return true
        }
        return Date().timeIntervalSince(modified) > Self.catalogTTL
    }

    // MARK: - Profile Cache

    private func cacheProfileText(_ text: String, id: String) {
        let dir = Self.fetchedProfilesDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(id).txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Failed to cache profile \(id): \(error.localizedDescription)")
        }
    }

    private func loadCachedProfile(id: String, name: String, measuredBy: String) -> AutoEQProfile? {
        let file = Self.fetchedProfilesDirectory.appendingPathComponent("\(id).txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        guard let profile = AutoEQParser.parse(text: text, name: name, source: .fetched, id: id) else { return nil }
        return AutoEQProfile(
            id: profile.id,
            name: profile.name,
            source: profile.source,
            preampDB: profile.preampDB,
            filters: profile.filters,
            measuredBy: measuredBy,
            optimizedSampleRate: 48000
        )
    }

    // MARK: - Errors

    enum FetchError: LocalizedError {
        case invalidURL
        case profileNotFound(String)
        case invalidData
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid profile URL"
            case .profileNotFound(let name): return "Profile not found: \(name)"
            case .invalidData: return "Invalid profile data"
            case .parseFailed(let name): return "Failed to parse profile: \(name)"
            }
        }
    }
}
