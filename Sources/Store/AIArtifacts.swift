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
    /// (Task 1's primary key) — `sources` is recorded in
    /// `ai_artifact_sources` against that SAME composite key (fix wave 2:
    /// no rowid indirection — see `Migrations.swift`'s `v6`), so provenance
    /// is stable across regenerations by construction, not by relying on
    /// SQLite never renumbering an implicit rowid. `sources` is still fully
    /// replaced (delete-then-reinsert, same pattern as
    /// `StoreWrites.replaceLabels`) so a regeneration with a different
    /// source set doesn't leave stale provenance rows for `purge` to trip
    /// over later.
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
        try db.execute(
            sql: """
                DELETE FROM ai_artifact_sources
                WHERE account_email = ? AND kind = ? AND artifact_key = ? AND model = ?
                  AND prompt_version = ?
                """,
            arguments: [account, kind, key, model, promptVersion])
        for messageID in sources {
            try db.execute(
                sql: """
                    INSERT INTO ai_artifact_sources
                        (account_email, kind, artifact_key, model, prompt_version, message_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [account, kind, key, model, promptVersion, messageID])
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
    /// message can't reach `ai_artifacts` via a foreign key: `ai_artifacts`
    /// has no single message it hangs off of (hence this table at all), so
    /// this walks the provenance table by hand instead — via the
    /// artifact's own composite key parts (fix wave 2: no rowid
    /// indirection, see `Migrations.swift`'s `v6` — a renumbered implicit
    /// rowid could previously have made this delete the WRONG artifact,
    /// a privacy invariant failure). Once ANY one of an artifact's sources
    /// is gone the cached content no longer reflects the thread, so the
    /// whole artifact — and every row of its provenance, not just the one
    /// for `sourceMessageID` — is invalidated together.
    static func purge(sourceMessageID: String, account: String, db: Database) throws {
        let affected = try Row.fetchAll(
            db,
            sql: """
                SELECT DISTINCT kind, artifact_key, model, prompt_version
                FROM ai_artifact_sources
                WHERE account_email = ? AND message_id = ?
                """,
            arguments: [account, sourceMessageID])
        for row in affected {
            let kind: String = row["kind"]
            let key: String = row["artifact_key"]
            let model: String = row["model"]
            let promptVersion: Int = row["prompt_version"]
            try db.execute(
                sql: """
                    DELETE FROM ai_artifacts
                    WHERE account_email = ? AND kind = ? AND artifact_key = ? AND model = ?
                      AND prompt_version = ?
                    """,
                arguments: [account, kind, key, model, promptVersion])
            try db.execute(
                sql: """
                    DELETE FROM ai_artifact_sources
                    WHERE account_email = ? AND kind = ? AND artifact_key = ? AND model = ?
                      AND prompt_version = ?
                    """,
                arguments: [account, kind, key, model, promptVersion])
        }
    }
}
