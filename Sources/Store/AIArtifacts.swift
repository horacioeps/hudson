import GRDB

/// Keeps `ai_artifacts`/`ai_artifact_sources` (Task 1's schema) consistent —
/// the content-addressed cache M7's summarize/draft/ask-inbox features will
/// read and write, plus the provenance table that lets a source message's
/// deletion purge whatever artifact it fed. No LLM call, provider, or
/// network code happens here or anywhere in Store — this only stores,
/// reads, and purges whatever M7 produces.
///
/// Every entry point here is synchronous and expects to run INSIDE the
/// caller's existing write transaction (same `db` connection), matching
/// `FTSIndex`'s convention — none of them open a transaction of their own.
enum AIArtifacts {
    /// Upserts one cached artifact and replaces its source provenance.
    /// `(account, kind, artifactKey, model, promptVersion)` is the cache key
    /// (Task 1's primary key) — an upsert on that key is an UPDATE, so the
    /// row's rowid (and hence `ai_artifact_sources.artifact_rowid`) stays
    /// stable across regenerations. `sources` is still fully replaced
    /// (delete-then-reinsert, same pattern as `StoreWrites.replaceLabels`)
    /// so a regeneration with a different source set doesn't leave stale
    /// provenance rows for `purge` to trip over later.
    static func put(
        kind: String, key: String, model: String, promptVersion: Int, content: String,
        sources: [String], account: String, createdAt: Int64, db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_artifacts
                    (account_email, kind, artifact_key, model, prompt_version, content, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_email, kind, artifact_key, model, prompt_version) DO UPDATE SET
                    content = excluded.content, created_at = excluded.created_at
                """,
            arguments: [account, kind, key, model, promptVersion, content, createdAt])
        // Not `db.lastInsertedRowID`: SQLite leaves that unchanged when the
        // ON CONFLICT DO UPDATE branch fires (only a genuine INSERT bumps
        // it), so an upsert of an EXISTING row would silently read back a
        // stale/unrelated rowid. A direct re-SELECT is correct either way.
        guard
            let rowid = try Int64.fetchOne(
                db,
                sql: """
                    SELECT rowid FROM ai_artifacts
                    WHERE account_email = ? AND kind = ? AND artifact_key = ? AND model = ?
                      AND prompt_version = ?
                    """,
                arguments: [account, kind, key, model, promptVersion])
        else {
            throw DatabaseError(
                resultCode: .SQLITE_ERROR,
                message: "AIArtifacts.put: upsert did not produce a row")
        }
        try db.execute(
            sql: "DELETE FROM ai_artifact_sources WHERE account_email = ? AND artifact_rowid = ?",
            arguments: [account, rowid])
        for messageID in sources {
            try db.execute(
                sql: """
                    INSERT INTO ai_artifact_sources (account_email, artifact_rowid, message_id)
                    VALUES (?, ?, ?)
                    """,
                arguments: [account, rowid, messageID])
        }
    }

    /// Cache read — the cached content, or `nil` on a miss (never generated,
    /// purged by a source deletion, or a `model`/`promptVersion` bump that
    /// changed the cache key).
    static func get(
        kind: String, key: String, model: String, promptVersion: Int, account: String, db: Database
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                SELECT content FROM ai_artifacts
                WHERE account_email = ? AND kind = ? AND artifact_key = ? AND model = ?
                  AND prompt_version = ?
                """,
            arguments: [account, kind, key, model, promptVersion])
    }

    /// Purges every artifact `sourceMessageID` fed, plus ALL of that
    /// artifact's provenance rows (not just this message's) — called from
    /// `deleteVanishedMessage` and the `.deleted` history branch, in the
    /// SAME transaction as the message delete. A cascade from the deleted
    /// message can't reach `ai_artifacts` via a foreign key: Task 1's
    /// `ai_artifact_sources` deliberately stores the artifact's rowid rather
    /// than an FK-bound reference (see `Migrations.swift`), precisely so a
    /// source row survives independently of artifact regeneration — so this
    /// walks the provenance table by hand instead. A thread-keyed summary
    /// has no single message it hangs off of (hence this table at all), and
    /// once ANY one of its sources is gone the cached content no longer
    /// reflects the thread, so the whole artifact — and every row of its
    /// provenance, not just the one for `sourceMessageID` — is invalidated
    /// together.
    static func purge(sourceMessageID: String, account: String, db: Database) throws {
        let rowids = try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT artifact_rowid FROM ai_artifact_sources
                WHERE account_email = ? AND message_id = ?
                """,
            arguments: [account, sourceMessageID])
        for rowid in rowids {
            try db.execute(
                sql: "DELETE FROM ai_artifacts WHERE account_email = ? AND rowid = ?",
                arguments: [account, rowid])
            try db.execute(
                sql: "DELETE FROM ai_artifact_sources WHERE account_email = ? AND artifact_rowid = ?",
                arguments: [account, rowid])
        }
    }
}
