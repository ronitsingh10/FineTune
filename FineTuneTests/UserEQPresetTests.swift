// FineTuneTests/UserEQPresetTests.swift
// Tests for UserEQPreset model and SettingsManager CRUD operations.
// Uses temp directories — no real settings files affected.

import Testing
import Foundation
@testable import FineTune

// MARK: - UserEQPreset — Model Contract

@Suite("UserEQPreset — Model")
@MainActor
struct UserEQPresetModelTests {

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let settings = EQSettings(bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], isEnabled: false)
        let preset = UserEQPreset(id: id, name: "Test Preset", settings: settings, createdAt: date)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(UserEQPreset.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.name == "Test Preset")
        #expect(decoded.settings.bandGains == settings.bandGains)
        #expect(decoded.createdAt == date)
    }

    @Test("Equatable compares all fields")
    func equatable() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 500_000)
        let settings = EQSettings(bandGains: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let a = UserEQPreset(id: id, name: "A", settings: settings, createdAt: date)
        let b = UserEQPreset(id: id, name: "A", settings: settings, createdAt: date)
        #expect(a == b)
    }

    @Test("Different IDs make presets non-equal")
    func differentIDsNotEqual() {
        let settings = EQSettings()
        let date = Date()
        let a = UserEQPreset(id: UUID(), name: "Same", settings: settings, createdAt: date)
        let b = UserEQPreset(id: UUID(), name: "Same", settings: settings, createdAt: date)
        #expect(a != b)
    }

    @Test("Default init generates unique IDs")
    func defaultInitUniqueIDs() {
        let a = UserEQPreset(name: "A", settings: EQSettings())
        let b = UserEQPreset(name: "B", settings: EQSettings())
        #expect(a.id != b.id)
    }

    @Test("isEnabled in EQSettings is carried but semantically ignored for presets")
    func isEnabledCarriedInSettings() throws {
        // UserEQPreset stores the full EQSettings, including isEnabled.
        // Per the model contract, callers should copy bandGains only when applying.
        // This test verifies the field round-trips (it's not stripped on encode).
        let withEnabled = UserEQPreset(
            name: "Enabled",
            settings: EQSettings(bandGains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isEnabled: true)
        )
        let withDisabled = UserEQPreset(
            name: "Disabled",
            settings: EQSettings(bandGains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isEnabled: false)
        )

        let dataE = try JSONEncoder().encode(withEnabled)
        let dataD = try JSONEncoder().encode(withDisabled)
        let decodedE = try JSONDecoder().decode(UserEQPreset.self, from: dataE)
        let decodedD = try JSONDecoder().decode(UserEQPreset.self, from: dataD)

        #expect(decodedE.settings.isEnabled == true)
        #expect(decodedD.settings.isEnabled == false)
        // Both have the same bandGains — only isEnabled differs
        #expect(decodedE.settings.bandGains == decodedD.settings.bandGains)
    }
}

// MARK: - SettingsManager — User EQ Preset CRUD

@Suite("SettingsManager — User EQ Preset CRUD")
@MainActor
struct UserEQPresetCRUDTests {

    /// Creates a fresh SettingsManager backed by a temporary directory.
    private func makeTempManager() throws -> (SettingsManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = SettingsManager(directory: dir)
        return (manager, dir)
    }

    private func cleanupDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Create

    @Test("createUserPreset returns preset with matching name and bandGains")
    func createReturnsPreset() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let gains: [Float] = [6, 3, 0, -3, -6, 0, 3, 6, 3, 0]
        let eq = EQSettings(bandGains: gains)
        let preset = manager.createUserPreset(name: "Bass Heavy", settings: eq)

        #expect(preset.name == "Bass Heavy")
        #expect(preset.settings.bandGains == gains)
    }

    @Test("createUserPreset generates a unique UUID")
    func createGeneratesUniqueID() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let a = manager.createUserPreset(name: "A", settings: EQSettings())
        let b = manager.createUserPreset(name: "B", settings: EQSettings())

        #expect(a.id != b.id)
    }

    @Test("createUserPreset with empty name falls back to Untitled")
    func createEmptyName() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "", settings: EQSettings())
        #expect(preset.name == "Untitled")

        let presets = manager.getUserPresets()
        #expect(presets.count == 1)
        #expect(presets[0].name == "Untitled")
    }

    @Test("createUserPreset auto-suffixes duplicate names Finder-style")
    func createDuplicateNames() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let a = manager.createUserPreset(name: "Same Name", settings: EQSettings())
        let b = manager.createUserPreset(name: "Same Name", settings: EQSettings())

        #expect(a.id != b.id)
        #expect(a.name == "Same Name")
        #expect(b.name == "Same Name (2)")

        let presets = manager.getUserPresets()
        #expect(presets.count == 2)
        let names = Set(presets.map(\.name))
        #expect(names == ["Same Name", "Same Name (2)"])
    }

    // MARK: - Read

    @Test("getUserPresets returns empty array when no presets exist")
    func getPresetsEmpty() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let presets = manager.getUserPresets()
        #expect(presets.isEmpty)
    }

    @Test("getUserPresets returns presets sorted by createdAt descending (newest first)")
    func getPresetsSortedNewestFirst() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        // Create presets with known timestamps via the model, then verify order
        // Since createUserPreset uses Date(), we create with slight delays conceptually.
        // But we can't control the date. Instead, create multiple and verify count + order.
        let first = manager.createUserPreset(name: "First", settings: EQSettings())
        let second = manager.createUserPreset(name: "Second", settings: EQSettings())
        let third = manager.createUserPreset(name: "Third", settings: EQSettings())

        let presets = manager.getUserPresets()
        #expect(presets.count == 3)

        // Newest first: third should be first or tied (same millisecond possible).
        // Verify the order is non-ascending by createdAt.
        for i in 0..<(presets.count - 1) {
            #expect(presets[i].createdAt >= presets[i + 1].createdAt,
                    "Preset at index \(i) should be newer than or equal to index \(i + 1)")
        }

        // Verify all three IDs are present
        let ids = Set(presets.map(\.id))
        #expect(ids.contains(first.id))
        #expect(ids.contains(second.id))
        #expect(ids.contains(third.id))
    }

    @Test("getUserPresets returns all created presets")
    func getPresetsReturnsAll() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        for i in 0..<5 {
            manager.createUserPreset(name: "Preset \(i)", settings: EQSettings())
        }

        let presets = manager.getUserPresets()
        #expect(presets.count == 5)
    }

    // MARK: - Update (Rename)

    @Test("updateUserPreset renames an existing preset")
    func renameExisting() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "Original", settings: EQSettings())
        manager.updateUserPreset(id: preset.id, name: "Renamed")

        let presets = manager.getUserPresets()
        let found = try #require(presets.first { $0.id == preset.id })
        #expect(found.name == "Renamed")
    }

    @Test("updateUserPreset with nonexistent ID is a no-op (no crash)")
    func renameNonexistentID() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "Keep", settings: EQSettings())

        // Rename a UUID that doesn't exist — should not crash or affect existing presets
        manager.updateUserPreset(id: UUID(), name: "Ghost")

        let presets = manager.getUserPresets()
        #expect(presets.count == 1)
        #expect(presets[0].name == "Keep")
        #expect(presets[0].id == preset.id)
    }

    @Test("updateUserPreset preserves bandGains and other fields")
    func renamePreservesBandGains() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let gains: [Float] = [12, -12, 6, -6, 3, -3, 0, 1, -1, 5]
        let preset = manager.createUserPreset(
            name: "Before",
            settings: EQSettings(bandGains: gains)
        )

        manager.updateUserPreset(id: preset.id, name: "After")

        let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
        #expect(found.name == "After")
        #expect(found.settings.bandGains == gains)
        #expect(found.createdAt == preset.createdAt)
    }

    @Test("updateUserPreset with empty name is a no-op (keeps old name)")
    func renameToEmpty() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "Had a Name", settings: EQSettings())
        manager.updateUserPreset(id: preset.id, name: "")

        let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
        #expect(found.name == "Had a Name")
    }

    // MARK: - Delete

    @Test("deleteUserPreset removes the preset by ID")
    func deleteExisting() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "ToDelete", settings: EQSettings())
        #expect(manager.getUserPresets().count == 1)

        manager.deleteUserPreset(id: preset.id)
        #expect(manager.getUserPresets().isEmpty)
    }

    @Test("deleteUserPreset with nonexistent ID is a no-op (no crash)")
    func deleteNonexistentID() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "Keep", settings: EQSettings())

        // Delete a UUID that doesn't exist
        manager.deleteUserPreset(id: UUID())

        let presets = manager.getUserPresets()
        #expect(presets.count == 1)
        #expect(presets[0].id == preset.id)
    }

    @Test("deleteUserPreset only removes the targeted preset, not others")
    func deleteOnlyTarget() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let a = manager.createUserPreset(name: "A", settings: EQSettings())
        let b = manager.createUserPreset(name: "B", settings: EQSettings())
        let c = manager.createUserPreset(name: "C", settings: EQSettings())

        manager.deleteUserPreset(id: b.id)

        let presets = manager.getUserPresets()
        #expect(presets.count == 2)
        let ids = Set(presets.map(\.id))
        #expect(ids.contains(a.id))
        #expect(ids.contains(c.id))
        #expect(!ids.contains(b.id))
    }

    @Test("Deleting all presets one by one leaves empty list")
    func deleteAllOneByOne() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let presets = (0..<3).map { i in
            manager.createUserPreset(name: "Preset \(i)", settings: EQSettings())
        }

        for preset in presets {
            manager.deleteUserPreset(id: preset.id)
        }

        #expect(manager.getUserPresets().isEmpty)
    }

    @Test("Double-deleting the same ID is a no-op on second call")
    func doubleDelete() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "Once", settings: EQSettings())
        manager.deleteUserPreset(id: preset.id)
        #expect(manager.getUserPresets().isEmpty)

        // Second delete — should not crash
        manager.deleteUserPreset(id: preset.id)
        #expect(manager.getUserPresets().isEmpty)
    }

    // MARK: - Create + Delete interleaving

    @Test("Create after delete reuses no state from deleted preset")
    func createAfterDelete() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let old = manager.createUserPreset(name: "Old", settings: EQSettings(bandGains: [12, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        manager.deleteUserPreset(id: old.id)

        let new = manager.createUserPreset(name: "New", settings: EQSettings(bandGains: [-6, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(new.id != old.id)
        #expect(new.name == "New")
        #expect(new.settings.bandGains[0] == -6)

        let presets = manager.getUserPresets()
        #expect(presets.count == 1)
    }
}

// MARK: - SettingsManager — User EQ Preset Name Validation

@Suite("SettingsManager — User EQ Preset Name Validation")
@MainActor
struct UserEQPresetNameValidationTests {

    private func makeTempManager() throws -> (SettingsManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = SettingsManager(directory: dir)
        return (manager, dir)
    }

    private func cleanupDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Whitespace Trimming

    @Test("createUserPreset trims leading and trailing whitespace")
    func createTrimsWhitespace() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "  Padded Name  ", settings: EQSettings())
        #expect(preset.name == "Padded Name")
    }

    @Test("createUserPreset trims tabs and newlines")
    func createTrimsTabsAndNewlines() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "\t\nTabbed\n\t", settings: EQSettings())
        #expect(preset.name == "Tabbed")
    }

    @Test("createUserPreset with whitespace-only name falls back to Untitled")
    func createWhitespaceOnlyName() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "   ", settings: EQSettings())
        #expect(preset.name == "Untitled")
    }

    @Test("updateUserPreset trims whitespace on rename")
    func renameTrimsWhitespace() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "Original", settings: EQSettings())
        manager.updateUserPreset(id: preset.id, name: "  Trimmed  ")

        let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
        #expect(found.name == "Trimmed")
    }

    @Test("updateUserPreset with whitespace-only name is a no-op")
    func renameWhitespaceOnlyNoOp() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "Keep This", settings: EQSettings())
        manager.updateUserPreset(id: preset.id, name: "   \t\n  ")

        let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
        #expect(found.name == "Keep This")
    }

    // MARK: - Finder-Style Dedup Chain

    @Test("Duplicate names produce sequential suffixes: Name, Name (2), Name (3)")
    func finderDedupChain() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let a = manager.createUserPreset(name: "Rock", settings: EQSettings())
        let b = manager.createUserPreset(name: "Rock", settings: EQSettings())
        let c = manager.createUserPreset(name: "Rock", settings: EQSettings())

        #expect(a.name == "Rock")
        #expect(b.name == "Rock (2)")
        #expect(c.name == "Rock (3)")
    }

    @Test("Dedup chain skips existing suffixed names to find next available")
    func dedupChainSkipsExisting() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        // Create "Jazz" and "Jazz (2)" manually
        manager.createUserPreset(name: "Jazz", settings: EQSettings())
        manager.createUserPreset(name: "Jazz (2)", settings: EQSettings())

        // Next "Jazz" should skip to (3) since (2) is taken by a differently-named preset
        let third = manager.createUserPreset(name: "Jazz", settings: EQSettings())
        #expect(third.name == "Jazz (3)")
    }

    @Test("Multiple Untitled presets follow dedup chain")
    func multipleUntitledDedup() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let a = manager.createUserPreset(name: "", settings: EQSettings())
        let b = manager.createUserPreset(name: "", settings: EQSettings())
        let c = manager.createUserPreset(name: "   ", settings: EQSettings())

        #expect(a.name == "Untitled")
        #expect(b.name == "Untitled (2)")
        #expect(c.name == "Untitled (3)")
    }

    // MARK: - Rename Collision Handling

    @Test("Rename to own current name produces no suffix (excludeID)")
    func renameToSelfNoSuffix() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let preset = manager.createUserPreset(name: "MyPreset", settings: EQSettings())
        manager.updateUserPreset(id: preset.id, name: "MyPreset")

        let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
        #expect(found.name == "MyPreset")
    }

    @Test("Rename colliding with another preset auto-suffixes")
    func renameCollisionAutoSuffixes() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let a = manager.createUserPreset(name: "Bass", settings: EQSettings())
        let b = manager.createUserPreset(name: "Treble", settings: EQSettings())

        // Rename b to collide with a's name
        manager.updateUserPreset(id: b.id, name: "Bass")

        let foundA = try #require(manager.getUserPresets().first { $0.id == a.id })
        let foundB = try #require(manager.getUserPresets().first { $0.id == b.id })
        #expect(foundA.name == "Bass")
        #expect(foundB.name == "Bass (2)")
    }

    @Test("Rename with trimmed result colliding gets suffixed")
    func renameTrimmedCollision() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        manager.createUserPreset(name: "Vocal", settings: EQSettings())
        let b = manager.createUserPreset(name: "Other", settings: EQSettings())

        // Rename b with padded whitespace that trims to match existing "Vocal"
        manager.updateUserPreset(id: b.id, name: "  Vocal  ")

        let foundB = try #require(manager.getUserPresets().first { $0.id == b.id })
        #expect(foundB.name == "Vocal (2)")
    }

    // MARK: - Edge Cases

    @Test("Dedup handles names that already contain parenthesized numbers")
    func dedupWithExistingParenNumbers() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        // Create a preset whose base name already looks like a suffixed name
        let a = manager.createUserPreset(name: "Preset (2)", settings: EQSettings())
        let b = manager.createUserPreset(name: "Preset (2)", settings: EQSettings())

        #expect(a.name == "Preset (2)")
        #expect(b.name == "Preset (2) (2)")
    }

    @Test("Deleting a preset frees its name for reuse without suffix")
    func deleteFreesNameForReuse() throws {
        let (manager, dir) = try makeTempManager()
        defer { cleanupDir(dir) }

        let first = manager.createUserPreset(name: "Ephemeral", settings: EQSettings())
        manager.deleteUserPreset(id: first.id)

        let reused = manager.createUserPreset(name: "Ephemeral", settings: EQSettings())
        #expect(reused.name == "Ephemeral")
    }
}

// MARK: - SettingsManager — User EQ Preset Persistence

@Suite("SettingsManager — User EQ Preset Persistence", .serialized)
@MainActor
struct UserEQPresetPersistenceTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanupDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Created preset survives SettingsManager re-init from same directory")
    func persistenceRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        // Phase 1: Create preset and wait for debounced save
        let manager1 = SettingsManager(directory: dir)
        let gains: [Float] = [3, 6, 9, 6, 3, 0, -3, -6, -9, -6]
        let created = manager1.createUserPreset(
            name: "Persistent Preset",
            settings: EQSettings(bandGains: gains)
        )

        // Wait for debounced save (500ms debounce + margin)
        try await Task.sleep(for: .milliseconds(1200))

        // Phase 2: Re-init from same directory and verify
        let manager2 = SettingsManager(directory: dir)
        let presets = manager2.getUserPresets()

        #expect(presets.count == 1)
        let loaded = try #require(presets.first)
        #expect(loaded.id == created.id)
        #expect(loaded.name == "Persistent Preset")
        #expect(loaded.settings.bandGains == gains)
    }

    @Test("Multiple presets survive persistence round-trip in correct order")
    func multiplePresetsRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let manager1 = SettingsManager(directory: dir)
        let first = manager1.createUserPreset(name: "First", settings: EQSettings(bandGains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        let second = manager1.createUserPreset(name: "Second", settings: EQSettings(bandGains: [2, 0, 0, 0, 0, 0, 0, 0, 0, 0]))

        try await Task.sleep(for: .milliseconds(1200))

        let manager2 = SettingsManager(directory: dir)
        let presets = manager2.getUserPresets()

        #expect(presets.count == 2)
        let ids = Set(presets.map(\.id))
        #expect(ids.contains(first.id))
        #expect(ids.contains(second.id))
    }

    @Test("Deleted preset does not survive persistence round-trip")
    func deletePersistedRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let manager1 = SettingsManager(directory: dir)
        let preset = manager1.createUserPreset(name: "Ephemeral", settings: EQSettings())
        manager1.deleteUserPreset(id: preset.id)

        try await Task.sleep(for: .milliseconds(1200))

        let manager2 = SettingsManager(directory: dir)
        #expect(manager2.getUserPresets().isEmpty)
    }

    @Test("Renamed preset persists with new name")
    func renamePersistedRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let manager1 = SettingsManager(directory: dir)
        let preset = manager1.createUserPreset(name: "Before", settings: EQSettings())
        manager1.updateUserPreset(id: preset.id, name: "After")

        try await Task.sleep(for: .milliseconds(1200))

        let manager2 = SettingsManager(directory: dir)
        let loaded = try #require(manager2.getUserPresets().first { $0.id == preset.id })
        #expect(loaded.name == "After")
    }
}

// MARK: - Settings Version

@Suite("Settings — Version for user EQ presets")
@MainActor
struct SettingsVersionTests {

    @Test("Default Settings().version is 11")
    func defaultVersion() {
        let settings = SettingsManager.Settings()
        #expect(settings.version == 11)
    }

    @Test("userEQPresets defaults to empty array in Settings()")
    func defaultUserEQPresetsEmpty() {
        let settings = SettingsManager.Settings()
        #expect(settings.userEQPresets.isEmpty)
    }

    @Test("Decoding JSON without userEQPresets key defaults to empty array")
    func decodeWithoutUserEQPresets() throws {
        let json = #"{"version": 10}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.userEQPresets.isEmpty)
    }

    @Test("Decoding JSON with userEQPresets array preserves presets")
    func decodeWithUserEQPresets() throws {
        let json = """
        {
            "version": 10,
            "userEQPresets": [
                {
                    "id": "550E8400-E29B-41D4-A716-446655440000",
                    "name": "My Preset",
                    "settings": {"bandGains": [1,2,3,4,5,6,7,8,9,10], "isEnabled": true},
                    "createdAt": 1000000
                }
            ]
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.userEQPresets.count == 1)
        #expect(decoded.userEQPresets[0].name == "My Preset")
        #expect(decoded.userEQPresets[0].settings.bandGains == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }
}
