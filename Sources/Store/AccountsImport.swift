import Foundation
import GRDB

/// Core logic for importing M1's legacy accounts.json into the database.
/// Pure: decodes file, performs atomic import, handles stale destination.
/// Testable without HudsonCLI dependencies.
public enum AccountsImport {
    /// M1 legacy format: email, clientID, and consentedAt (bare Double from JSONEncoder default).
    private struct LegacyAccount: Decodable {
        let email: String
        let clientID: String
        let consentedAt: Date

        enum CodingKeys: String, CodingKey {
            case email, clientID = "clientID", consentedAt = "consentedAt"
        }
    }

    /// Imports legacy accounts.json into the database in a single atomic transaction.
    /// - Parameter url: Path to accounts.json (typically ~/Library/Application Support/Hudson/accounts.json).
    /// - Parameter database: The GRDB store to import into.
    /// - Returns: true if an import occurred; false if skipped (file missing or table non-empty).
    /// - Throws: On decode failures (e.g. ISO8601 format — indicates wrong date strategy).
    public static func importLegacyFile(at url: URL, database: HudsonDatabase) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard try await database.primaryAccount() == nil else { return false }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // CRITICAL: M1 wrote dates as bare Double (Foundation's default Date coding strategy).
        // Never use .iso8601; that will reject all M1 accounts.json files.
        let legacy = try decoder.decode([LegacyAccount].self, from: data)

        // Atomic import: one transaction for all accounts, so a crash leaves the table empty
        // and the next run retries from the start.
        try await database.writer.write { db in
            for account in legacy {
                try db.execute(
                    sql: """
                        INSERT INTO accounts (email, client_id, consented_at) VALUES (?, ?, ?)
                        ON CONFLICT(email) DO UPDATE SET
                            client_id = excluded.client_id, consented_at = excluded.consented_at
                        """,
                    arguments: [
                        account.email,
                        account.clientID,
                        account.consentedAt.timeIntervalSinceReferenceDate
                    ])
            }
        }

        // Atomic import succeeded; now rename with stale-destination handling.
        let destination = url.deletingLastPathComponent().appending(path: "accounts.json.migrated")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            // Destination exists (stale from prior failed attempt); remove it and retry.
            // The DB is the source of truth, so this is safe.
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
        }

        return true
    }
}
