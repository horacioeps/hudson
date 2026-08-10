import Foundation
import GRDB
import OSLog

/// Store-layer log, scoped here since Store imports neither GmailKit (home of
/// the shared `Log` enum) nor networking. Content-free per spec §9.1: never
/// logs message ids or content, only that an apply error was contained.
private let storeLog = Logger(subsystem: "com.hudson.core", category: "store")

extension HudsonDatabase {
    /// Writes a snapshot through the §4.2 version guard. Inside one
    /// transaction: tombstone check → history_id comparison → upsert.
    public func applySnapshot(
        _ snapshot: MessageSnapshot, account: String
    ) async throws -> SnapshotOutcome {
        try await writer.write { db in
            try Self.applySnapshotInTransaction(snapshot, account: account, db: db)
        }
    }

    /// Applies a page of snapshots in ONE transaction, each guarded by a
    /// SAVEPOINT so a single failing/stale row rolls back only itself. Cutting
    /// commits from per-message to per-page is the load-bearing control against
    /// the SwiftUI ValueObservation storm during the ~6h backfill (architecture M3).
    public func applySnapshots(
        _ snapshots: [MessageSnapshot], account: String
    ) async throws -> Int {
        try await writer.write { db in
            var applied = 0
            for snapshot in snapshots {
                do {
                    try db.execute(sql: "SAVEPOINT s")
                    let outcome = try Self.applySnapshotInTransaction(snapshot, account: account, db: db)
                    try db.execute(sql: "RELEASE s")
                    if outcome == .applied { applied += 1 }
                } catch {
                    try db.execute(sql: "ROLLBACK TO s")
                    try db.execute(sql: "RELEASE s")
                    // Never silent: a genuine bad-data error during the ~6h
                    // backfill must be visible, even though it's contained to
                    // this one message. No id/content logged (spec §9.1).
                    storeLog.warning("applySnapshots: skipped a message on apply error")
                }
            }
            return applied
        }
    }

    /// Applies history changes in order and advances the cursor — all in ONE
    /// transaction, so a crash resumes cleanly from the stored cursor (§4.3).
    /// Returns ids of label events targeting unknown, non-tombstoned
    /// messages: these must be hydrated by the caller — a `.labels` event
    /// alone can't materialize a message row (no thread/subject/snippet/etc.),
    /// so without hydration the message would stay permanently missing from
    /// the store rather than merely converging slower (spec §4.1).
    public func applyHistory(
        _ changes: [HistoryChange], newCursor: Int64, account: String
    ) async throws -> [String] {
        try await writer.write { db in
            var unknownIDs: [String] = []
            for change in changes {
                switch change.kind {
                case .added(let snapshot):
                    _ = try Self.applySnapshotInTransaction(snapshot, account: account, db: db)
                case .deleted(let id):
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO tombstones (account_email, message_id) VALUES (?, ?)",
                        arguments: [account, id])
                    try db.execute(
                        sql: "DELETE FROM messages WHERE account_email = ? AND id = ?",
                        arguments: [account, id])
                case .labels(let id, let historyID, let labelIDs):
                    let exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE account_email = ? AND id = ?)",
                        arguments: [account, id]) ?? false
                    guard exists else {
                        // A tombstoned id is known-deleted, not unknown — don't
                        // hand it back for hydration (it would just 404 forever).
                        let tombstoned = try Bool.fetchOne(
                            db,
                            sql: "SELECT EXISTS(SELECT 1 FROM tombstones WHERE account_email = ? AND message_id = ?)",
                            arguments: [account, id]) ?? false
                        if !tombstoned && !unknownIDs.contains(id) {
                            unknownIDs.append(id)
                        }
                        continue
                    }
                    let stored = try Int64.fetchOne(
                        db,
                        sql: "SELECT history_id FROM messages WHERE account_email = ? AND id = ?",
                        arguments: [account, id]) ?? 0
                    guard historyID >= stored else { continue }
                    try db.execute(
                        sql: "UPDATE messages SET history_id = ? WHERE account_email = ? AND id = ?",
                        arguments: [historyID, account, id])
                    try Self.replaceLabels(labelIDs, messageID: id, account: account, db: db)
                }
            }
            try db.execute(
                sql: "UPDATE accounts SET history_cursor = ? WHERE email = ?",
                arguments: [newCursor, account])
            // §4.3 requires the cursor advance to be atomic with the applied
            // changes — if there's no accounts row to update, fail loudly
            // rather than silently reporting success with a stale cursor.
            guard db.changesCount == 1 else {
                throw DatabaseError(
                    resultCode: .SQLITE_ERROR,
                    message: "applyHistory: no accounts row for '\(account)' — cursor not advanced")
            }
            return unknownIDs
        }
    }

    /// Removes a message that provably no longer exists server-side (a
    /// hydration `getMessage` 404 — see `SyncEngine.hydrateBodies`). Mirrors
    /// the `.deleted` branch of `applyHistory`: tombstone then delete, in ONE
    /// transaction, so the row leaves `messageIDsNeedingBodies`'s work-list
    /// instead of 404ing forever. `message_bodies`/`message_labels` rows
    /// cascade via their foreign keys.
    public func deleteVanishedMessage(id: String, account: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO tombstones (account_email, message_id) VALUES (?, ?)",
                arguments: [account, id])
            try db.execute(
                sql: "DELETE FROM messages WHERE account_email = ? AND id = ?",
                arguments: [account, id])
        }
    }

    /// Caches Gmail's label id→name mapping for display.
    public func upsertLabels(
        _ labels: [(id: String, name: String)], account: String
    ) async throws {
        try await writer.write { db in
            for label in labels {
                try db.execute(
                    sql: """
                        INSERT INTO labels (account_email, id, name) VALUES (?, ?, ?)
                        ON CONFLICT(account_email, id) DO UPDATE SET name = excluded.name
                        """,
                    arguments: [account, label.id, label.name])
            }
        }
    }

    // MARK: - Transaction bodies (synchronous, called inside writer.write)

    static func applySnapshotInTransaction(
        _ snapshot: MessageSnapshot, account: String, db: Database
    ) throws -> SnapshotOutcome {
        let tombstoned = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM tombstones WHERE account_email = ? AND message_id = ?)",
            arguments: [account, snapshot.id]) ?? false
        if tombstoned { return .tombstoned }

        if let stored = try Int64.fetchOne(
            db,
            sql: "SELECT history_id FROM messages WHERE account_email = ? AND id = ?",
            arguments: [account, snapshot.id]), stored > snapshot.historyID {
            return .stale
        }

        try db.execute(
            sql: """
                INSERT INTO threads (account_email, id, last_message_at) VALUES (?, ?, ?)
                ON CONFLICT(account_email, id)
                DO UPDATE SET last_message_at = MAX(
                    IFNULL(last_message_at, excluded.last_message_at), excluded.last_message_at)
                """,
            arguments: [account, snapshot.threadID, snapshot.internalDate])
        try db.execute(
            sql: """
                INSERT INTO messages (account_email, id, thread_id, history_id, internal_date,
                                      from_line, to_line, subject, snippet)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_email, id) DO UPDATE SET
                    history_id = excluded.history_id,
                    thread_id = excluded.thread_id,
                    internal_date = excluded.internal_date,
                    from_line = excluded.from_line,
                    to_line = excluded.to_line,
                    subject = excluded.subject,
                    snippet = excluded.snippet
                """,
            arguments: [
                account, snapshot.id, snapshot.threadID, snapshot.historyID,
                snapshot.internalDate, snapshot.fromLine, snapshot.toLine,
                snapshot.subject, snapshot.snippet,
            ])
        try replaceLabels(snapshot.labelIDs, messageID: snapshot.id, account: account, db: db)
        return .applied
    }

    static func replaceLabels(
        _ labelIDs: [String], messageID: String, account: String, db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM message_labels WHERE account_email = ? AND message_id = ?",
            arguments: [account, messageID])
        for labelID in labelIDs {
            try db.execute(
                sql: "INSERT OR IGNORE INTO message_labels (account_email, message_id, label_id) VALUES (?, ?, ?)",
                arguments: [account, messageID, labelID])
        }
    }
}
