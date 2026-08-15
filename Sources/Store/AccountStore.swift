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
    /// Denominator for the first-launch progress bar: the `resultSizeEstimate`
    /// from the FIRST page of the current backfill run, scoped to the same
    /// 90-day window the run itself lists (migration `v11`). `nil` until that
    /// page returns, and again whenever a run restarts.
    public let backfillTotalEstimate: Int?
    /// Windowed message count as it stood when the current backfill run
    /// STARTED (migration `v11`). `0` means this run is a genuine first
    /// download; anything higher means it is re-listing mail already on disk
    /// (a §4.3 cursor expiry, a `v10` upgrade, or a reconnect), which is not
    /// user-visible progress and therefore gets no bar. `nil` until seeded.
    public let backfillCountBaseline: Int?
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

    /// Removes the account row entirely — the Store half of "Disconnect
    /// account" (the other half is `KeychainTokenStore.deleteAll`, which the
    /// caller is responsible for running against the SAME `email` first).
    /// No FK from any other table references `accounts`, so this never needs
    /// to cascade: mail already synced to `messages`/`threads` is untouched,
    /// matching this feature's scope of forgetting the CONNECTION, not
    /// wiping locally cached mail. A no-op (not an error) if `email` was
    /// never connected — mirrors `TokenStore.deleteAll`'s own
    /// idempotent-on-miss contract.
    public func deleteAccount(email: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE email = ?", arguments: [email])
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

    /// Seeds the current backfill run's progress denominator and baseline —
    /// called once, on the FIRST page of a run (see
    /// `SyncEngine.backfill`). Both writes are `COALESCE`-guarded so they are
    /// sticky in SQL rather than by caller discipline: Gmail returns a
    /// slightly different `resultSizeEstimate` on later pages, and letting a
    /// later page move the denominator would make the bar jump backwards.
    /// Once set, only `clearBackfillProgressSeed` can change them.
    public func seedBackfillProgress(
        email: String, totalEstimate: Int?, countBaseline: Int
    ) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET backfill_total_estimate = COALESCE(backfill_total_estimate, ?),
                        backfill_count_baseline = COALESCE(backfill_count_baseline, ?)
                    WHERE email = ?
                    """,
                arguments: [totalEstimate, countBaseline, email])
        }
    }

    /// Restarts a backfill from page one and forgets the previous run's
    /// progress seeds — ONE transaction, deliberately.
    ///
    /// Splitting this into "reset the state" plus "clear the seeds" left a
    /// window that `seedBackfillProgress`'s COALESCE guard made permanent: a
    /// crash between the two writes leaves the run marked `pending` while the
    /// stale estimate and baseline survive, and because the seeds are sticky
    /// the new run can never overwrite them — so it re-lists forever under the
    /// previous run's numbers. Even without a crash, the intermediate commit
    /// is an observable emit (restarted state, stale seeds) that the UI's
    /// ratchet would pin.
    public func restartBackfill(email: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET backfill_state = 'pending', backfill_page_token = NULL,
                        backfill_total_estimate = NULL, backfill_count_baseline = NULL
                    WHERE email = ?
                    """,
                arguments: [email])
        }
    }

    static func accountRecord(from row: Row) -> AccountRecord {
        AccountRecord(
            email: row["email"], clientID: row["client_id"],
            consentedAt: Date(timeIntervalSinceReferenceDate: row["consented_at"]),
            historyCursor: row["history_cursor"], backfillState: row["backfill_state"],
            backfillPageToken: row["backfill_page_token"],
            backfilledCount: row["backfilled_count"],
            backfillTotalEstimate: row["backfill_total_estimate"],
            backfillCountBaseline: row["backfill_count_baseline"])
    }
}
