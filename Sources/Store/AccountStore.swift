import Foundation
import GRDB

/// One connected Gmail account as stored in SQLite (replaces M1's accounts.json).
public struct AccountRecord: Sendable, Equatable {
    public let email: String
    public let clientID: String
    public let consentedAt: Date
    public let historyCursor: Int64?
    public let backfillState: String
    public let backfillPageToken: String?
    public let backfilledCount: Int
}

extension HudsonDatabase {
    /// Inserts or updates an account. `consented_at` stores seconds since the
    /// reference date — the same encoding M1's accounts.json used, so migrated
    /// and fresh values are directly comparable.
    public func upsertAccount(email: String, clientID: String, consentedAt: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (email, client_id, consented_at) VALUES (?, ?, ?)
                    ON CONFLICT(email) DO UPDATE SET
                        client_id = excluded.client_id, consented_at = excluded.consented_at
                    """,
                arguments: [email, clientID, consentedAt.timeIntervalSinceReferenceDate])
        }
    }

    /// The stored record for one account, or nil if never connected.
    public func account(email: String) async throws -> AccountRecord? {
        try await writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM accounts WHERE email = ?", arguments: [email]
            ).map(Self.accountRecord(from:))
        }
    }

    /// The account CLI commands operate on (first alphabetically; M1 parity).
    public func primaryAccount() async throws -> AccountRecord? {
        try await writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM accounts ORDER BY email LIMIT 1"
            ).map(Self.accountRecord(from:))
        }
    }

    /// Persists backfill progress so a killed sync resumes where it stopped.
    public func updateBackfill(
        email: String, state: String, pageToken: String?, addedCount: Int
    ) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts SET backfill_state = ?, backfill_page_token = ?,
                        backfilled_count = backfilled_count + ? WHERE email = ?
                    """,
                arguments: [state, pageToken, addedCount, email])
        }
    }

    static func accountRecord(from row: Row) -> AccountRecord {
        AccountRecord(
            email: row["email"], clientID: row["client_id"],
            consentedAt: Date(timeIntervalSinceReferenceDate: row["consented_at"]),
            historyCursor: row["history_cursor"], backfillState: row["backfill_state"],
            backfillPageToken: row["backfill_page_token"],
            backfilledCount: row["backfilled_count"])
    }
}
