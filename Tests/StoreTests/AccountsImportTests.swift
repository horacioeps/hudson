import Foundation
import Testing
@testable import Store

@Test func importsLegacyAccountsAtomically() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "hudson-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let accountsURL = tempDir.appending(path: "accounts.json")
    let account1 = LegacyAccountJSON(
        email: "alice@example.com", clientID: "cid1",
        consentedAt: 800_000_000)
    let account2 = LegacyAccountJSON(
        email: "bob@example.com", clientID: "cid2",
        consentedAt: 810_000_000)
    let encoded = try JSONEncoder().encode([account1, account2])
    try encoded.write(to: accountsURL)

    let database = try HudsonDatabase.inMemory()
    let imported = try await AccountsImport.importLegacyFile(at: accountsURL, database: database)

    #expect(imported == true)
    #expect(FileManager.default.fileExists(atPath: accountsURL.path) == false)
    #expect(FileManager.default.fileExists(
        atPath: tempDir.appending(path: "accounts.json.migrated").path) == true)

    let alice = try #require(try await database.account(email: "alice@example.com"))
    #expect(alice.clientID == "cid1")
    #expect(abs(alice.consentedAt.timeIntervalSinceReferenceDate - 800_000_000) < 0.001)

    let bob = try #require(try await database.account(email: "bob@example.com"))
    #expect(bob.clientID == "cid2")
    #expect(abs(bob.consentedAt.timeIntervalSinceReferenceDate - 810_000_000) < 0.001)
}

@Test func isIdempotentWhenFileIsAbsent() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "hudson-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let accountsURL = tempDir.appending(path: "accounts.json")
    let database = try HudsonDatabase.inMemory()

    let imported = try await AccountsImport.importLegacyFile(at: accountsURL, database: database)

    #expect(imported == false)
}

@Test func isIdempotentWhenTableNonEmpty() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "hudson-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let accountsURL = tempDir.appending(path: "accounts.json")
    let legacy = LegacyAccountJSON(
        email: "alice@example.com", clientID: "cid1", consentedAt: 800_000_000)
    let encoded = try JSONEncoder().encode([legacy])
    try encoded.write(to: accountsURL)

    let database = try HudsonDatabase.inMemory()
    let imported1 = try await AccountsImport.importLegacyFile(at: accountsURL, database: database)
    #expect(imported1 == true)

    // Restore the file (in real scenario, a prior failed migration might leave it)
    try encoded.write(to: accountsURL)

    let imported2 = try await AccountsImport.importLegacyFile(at: accountsURL, database: database)
    #expect(imported2 == false)  // Skips because table is non-empty
    #expect(FileManager.default.fileExists(atPath: accountsURL.path) == true)  // File untouched
}

@Test func handlesStaleMigratedDestination() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "hudson-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let accountsURL = tempDir.appending(path: "accounts.json")
    let migratedURL = tempDir.appending(path: "accounts.json.migrated")

    let legacy = LegacyAccountJSON(
        email: "alice@example.com", clientID: "cid1", consentedAt: 800_000_000)
    let encoded = try JSONEncoder().encode([legacy])
    try encoded.write(to: accountsURL)

    // Create stale migrated file (simulating prior failed migration)
    try "stale".write(toFile: migratedURL.path, atomically: true, encoding: .utf8)

    let database = try HudsonDatabase.inMemory()
    let imported = try await AccountsImport.importLegacyFile(at: accountsURL, database: database)

    #expect(imported == true)
    #expect(FileManager.default.fileExists(atPath: accountsURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: migratedURL.path) == true)

    let contents = try String(contentsOf: migratedURL, encoding: .utf8)
    #expect(contents.contains("alice@example.com"))  // New migrated file, not the stale one
}

@Test func rejectsISO8601DateFormat() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "hudson-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let accountsURL = tempDir.appending(path: "accounts.json")
    let iso8601JSON = """
    [
      {
        "email": "alice@example.com",
        "clientID": "cid1",
        "consentedAt": "2025-08-10T12:00:00Z"
      }
    ]
    """
    try iso8601JSON.write(toFile: accountsURL.path, atomically: true, encoding: .utf8)

    let database = try HudsonDatabase.inMemory()
    var didThrow = false
    do {
        _ = try await AccountsImport.importLegacyFile(at: accountsURL, database: database)
    } catch {
        didThrow = true
    }
    #expect(didThrow == true)
}

@Test func acceptsDefaultDateStrategy() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "hudson-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let accountsURL = tempDir.appending(path: "accounts.json")
    let bareDoubleJSON = """
    [
      {
        "email": "alice@example.com",
        "clientID": "cid1",
        "consentedAt": 800000000
      }
    ]
    """
    try bareDoubleJSON.write(toFile: accountsURL.path, atomically: true, encoding: .utf8)

    let database = try HudsonDatabase.inMemory()
    let imported = try await AccountsImport.importLegacyFile(at: accountsURL, database: database)

    #expect(imported == true)
    let alice = try #require(try await database.account(email: "alice@example.com"))
    #expect(alice.clientID == "cid1")
}

// Helper: manually craft JSON instead of using Codable to control encoding
private struct LegacyAccountJSON: Encodable {
    let email: String
    let clientID: String
    let consentedAt: Double

    enum CodingKeys: String, CodingKey {
        case email, clientID = "clientID", consentedAt = "consentedAt"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(consentedAt, forKey: .consentedAt)
    }
}
