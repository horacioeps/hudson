import GRDB

/// Keeps `fts_messages` — a plain, non-external-content FTS5 virtual table
/// (see `Migrations.swift`'s v3) — consistent with `messages`/`message_bodies`
/// as a byproduct of the same write transactions that touch those tables.
///
/// A plain FTS5 table has no external-content auto-sync trigger machinery:
/// the app owns keeping the index correct. That's what this type does —
/// allocate/look up each message's dense integer rowid (`message_seq`, since
/// FTS5's implicit rowid must be an integer but the store's real primary key
/// is the composite TEXT `(account_email, message_id)`), and stub/reindex/
/// delete its `fts_messages` row in lockstep with `messages`/`message_bodies`
/// writes.
///
/// Every entry point here is synchronous and expects to run INSIDE the
/// caller's existing write transaction (same `db` connection) — none of them
/// open a transaction of their own.
enum FTSIndex {
    /// Looks up the existing `message_seq` rowid for `(account, messageID)`,
    /// or allocates a new one. Called by every other entry point here, so a
    /// message's FTS rowid is always the same value across its whole
    /// lifetime (insert → updates → delete).
    static func seq(for messageID: String, account: String, db: Database) throws -> Int64 {
        if let existing = try Int64.fetchOne(
            db,
            sql: "SELECT seq FROM message_seq WHERE account_email = ? AND message_id = ?",
            arguments: [account, messageID]
        ) {
            return existing
        }
        try db.execute(
            sql: "INSERT INTO message_seq (account_email, message_id) VALUES (?, ?)",
            arguments: [account, messageID])
        return db.lastInsertedRowID
    }

    /// Stubs (or re-stubs) `fts_messages` for a message insert/update — the
    /// subject/from/to/message_id/thread_id columns, at the message's `seq`
    /// rowid. Called from `applySnapshotInTransaction`, right after
    /// `messages` is upserted.
    ///
    /// A plain (non-contentless, non-external-content) FTS5 table supports
    /// ordinary `DELETE`/`INSERT` directly — SQLite keeps its internal index
    /// consistent itself, since (unlike an external-content table) FTS5 owns
    /// the storage here. That's simpler than the external-content
    /// delete-then-reinsert protocol (`INSERT INTO fts(fts, rowid, ...)
    /// VALUES('delete', ...)` with the OLD column values), which exists only
    /// to tell FTS5 what to remove from its index when the real content
    /// lives in a different table it doesn't automatically see. This call
    /// site doesn't retain old column values, so it uses the plain-table
    /// `DELETE FROM fts_messages WHERE rowid = ?` form — a harmless no-op on
    /// a fresh insert, since there's no existing row to remove.
    ///
    /// Body is deliberately NOT blanked here: a metadata-only re-stub (e.g.
    /// the routine cursor-expiry re-list re-applying an already-known
    /// message as an update) must not wipe out an already-indexed body, so
    /// this LEFT JOINs `message_bodies` and re-includes its current
    /// `plain_text` when present. `reindexBody` (via `saveBody`) is what
    /// adds the body once hydration actually derives one.
    static func stubIndex(_ snapshot: MessageSnapshot, account: String, db: Database) throws {
        let rowid = try seq(for: snapshot.id, account: account, db: db)
        try db.execute(sql: "DELETE FROM fts_messages WHERE rowid = ?", arguments: [rowid])
        try db.execute(
            sql: """
                INSERT INTO fts_messages (rowid, subject, from_addr, to_addr, body, message_id, thread_id)
                SELECT :rowid, :subject, :from_addr, :to_addr,
                       IFNULL((SELECT plain_text FROM message_bodies
                               WHERE account_email = :account AND message_id = :message_id), ''),
                       :message_id, :thread_id
                """,
            arguments: [
                "rowid": rowid, "subject": snapshot.subject, "from_addr": snapshot.fromLine,
                "to_addr": snapshot.toLine, "account": account, "message_id": snapshot.id,
                "thread_id": snapshot.threadID,
            ])
    }

    /// Re-indexes a message's FTS row WITH its body — called from `saveBody`
    /// once a sanitized plain-text body lands (including a re-derive after a
    /// `Sanitizer.version` bump). Re-fetches subject/from/to/thread_id from
    /// `messages` rather than trusting a caller-supplied copy, so a
    /// body-only update can never go stale on the other columns. Same
    /// plain-table delete-then-reinsert as `stubIndex` — see its doc comment.
    static func reindexBody(
        messageID: String, account: String, plainText: String, db: Database
    ) throws {
        // Existence check BEFORE `seq(for:)` (Fix round — M5 Task 7
        // carry-forward): `seq(for:)` INSERTs on a miss, so calling it
        // first would allocate a `message_seq` row for a message that
        // turns out not to exist, then hit the guard below and return —
        // leaving that row orphaned (no `fts_messages` entry, and this
        // early-return path never reaches `deleteIndex` to clean it up).
        guard
            let row = try Row.fetchOne(
                db,
                sql: "SELECT subject, from_line, to_line, thread_id FROM messages WHERE account_email = ? AND id = ?",
                arguments: [account, messageID])
        else {
            // Message row is gone (e.g. deleted between hydration fetch and
            // save) — nothing to index; `deleteIndex` already cleaned up.
            return
        }
        let rowid = try seq(for: messageID, account: account, db: db)
        try db.execute(sql: "DELETE FROM fts_messages WHERE rowid = ?", arguments: [rowid])
        try db.execute(
            sql: """
                INSERT INTO fts_messages (rowid, subject, from_addr, to_addr, body, message_id, thread_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                rowid, row["subject"] as String, row["from_line"] as String,
                row["to_line"] as String, plainText, messageID, row["thread_id"] as String,
            ])
    }

    /// Removes a message from the index entirely: its `fts_messages` row AND
    /// its `message_seq` rowid mapping. Called from `deleteVanishedMessage`
    /// and the `.deleted` history branch, alongside their `messages` row
    /// delete. Safe to call even if no `message_seq` row exists yet (a
    /// harmless no-op).
    static func deleteIndex(messageID: String, account: String, db: Database) throws {
        if let rowid = try Int64.fetchOne(
            db,
            sql: "SELECT seq FROM message_seq WHERE account_email = ? AND message_id = ?",
            arguments: [account, messageID]
        ) {
            try db.execute(sql: "DELETE FROM fts_messages WHERE rowid = ?", arguments: [rowid])
        }
        try db.execute(
            sql: "DELETE FROM message_seq WHERE account_email = ? AND message_id = ?",
            arguments: [account, messageID])
    }
}
