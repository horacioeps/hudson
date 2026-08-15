import Foundation
import GRDB

/// M7 pre-hooks: the storage/config/retrieval seam summarize/draft/ask-inbox
/// will graft onto. No LLM provider, prompt, or network code lives here —
/// only the cache table (`AIArtifacts`), per-feature configuration
/// (`ai_config`), and the two read shapes M7's context-building needs
/// (`threadMessages`, `sentMessages`).
extension HudsonDatabase {
    /// Upserts a cached AI artifact (a thread summary, a draft, an
    /// ask-inbox answer — M7 decides what `kind` means) and records which
    /// messages fed it, all in one transaction. Content-addressed:
    /// re-running the exact same `(kind, key, model, promptVersion)`
    /// overwrites in place rather than accumulating history, so M7's
    /// cache-or-regenerate check is just `artifact(...)` returning non-nil.
    /// `sources` are the message ids this artifact was derived from —
    /// recorded in `ai_artifact_sources` so a later deletion of any one of
    /// them purges this artifact (see `AIArtifacts.purge`,
    /// `deleteVanishedMessage`, the `.deleted` history branch). Pass `[]`
    /// for an artifact with no per-message provenance (e.g. a voice
    /// profile aggregated over many sent messages, none of which alone
    /// should invalidate it).
    public func putArtifact(
        kind: String, key: String, model: String, promptVersion: Int, content: String,
        sources: [String], account: String, createdAt: Int64
    ) async throws {
        try await writer.write { db in
            try AIArtifacts.put(
                kind: kind, key: key, model: model, promptVersion: promptVersion, content: content,
                sources: sources, account: account, createdAt: createdAt, db: db)
        }
    }

    /// Cache read — `nil` on a miss (never generated, purged by a source
    /// deletion, or a `model`/`promptVersion` bump that changed the cache
    /// key).
    public func artifact(
        kind: String, key: String, model: String, promptVersion: Int, account: String
    ) async throws -> String? {
        try await writer.read { db in
            try AIArtifacts.get(
                kind: kind, key: key, model: model, promptVersion: promptVersion, account: account,
                db: db)
        }
    }

    /// Reads one feature's AI configuration — `nil` if the user never
    /// configured it (M7's opt-in gate: no row means the feature has never
    /// been turned on).
    public func aiConfig(
        feature: String, account: String
    ) async throws -> (model: String, baseURL: String?, optIn: Bool)? {
        try await writer.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT model, base_url, opt_in FROM ai_config
                        WHERE account_email = ? AND feature = ?
                        """,
                    arguments: [account, feature])
            else { return nil }
            return (model: row["model"], baseURL: row["base_url"], optIn: row["opt_in"])
        }
    }

    /// Opts EVERY feature out for one account, leaving each row's `model` and
    /// `base_url` exactly as they were.
    ///
    /// Two jobs, both privacy-critical:
    ///
    /// 1. **Disconnecting an account must revoke its AI consent.** Deleting
    ///    the `accounts` row leaves `ai_config` untouched (there is no foreign
    ///    key), so without this a reconnect of the same address silently
    ///    resurrects an `opt_in = 1` granted in a previous session — consent
    ///    the user has no reason to think still exists.
    /// 2. **Turning AI off must not rewrite which provider it would use.** The
    ///    obvious implementation — re-`setAIConfig` every feature with
    ///    `model: ""`, `baseURL: nil` — also erases the provider encoding, so a
    ///    user running a LOCAL model, whose whole point is that nothing leaves
    ///    the machine, silently comes back as cloud Anthropic when re-enabled.
    ///    Flipping only `opt_in` cannot do that.
    public func revokeAIOptIn(account: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE ai_config SET opt_in = 0 WHERE account_email = ?",
                arguments: [account])
        }
    }

    /// Upserts one feature's AI configuration (model, optional custom base
    /// URL, opt-in flag).
    public func setAIConfig(
        feature: String, model: String, baseURL: String?, optIn: Bool, account: String
    ) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ai_config (account_email, feature, model, base_url, opt_in)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_email, feature) DO UPDATE SET
                        model = excluded.model, base_url = excluded.base_url, opt_in = excluded.opt_in
                    """,
                arguments: [account, feature, model, baseURL, optIn])
        }
    }

    /// One thread's messages, oldest-first — the context window M7's
    /// summarize/draft features build their prompt from. Reuses
    /// `StoreReads.messageRow`, so results are overlay-aware (effective
    /// labels, same composition as `recentMessages`/`message`); body text
    /// isn't part of `MessageRow` itself, so a caller needing content joins
    /// `message_bodies` the same way `message(id:account:)`'s caller does.
    public func threadMessages(threadID: String, account: String) async throws -> [MessageRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages WHERE account_email = ? AND thread_id = ?
                    ORDER BY internal_date ASC, id ASC
                    """,
                arguments: [account, threadID])
            return try rows.map { try Self.messageRow(from: $0, account: account, db: db) }
        }
    }

    /// Newest-first messages effectively labeled SENT, bounded by `limit` —
    /// the voice-profile source for M7's draft feature. Effective =
    /// (canonical `message_labels` ∪ pending `mutation_queue` adds) − pending
    /// removes — the shared `EffectiveLabels.fragment` overlay composition,
    /// so an optimistic label change is reflected here immediately, before
    /// it ever reaches Gmail.
    public func sentMessages(account: String, limit: Int) async throws -> [MessageRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages m
                    WHERE m.account_email = ?
                    AND EXISTS (
                        \(EffectiveLabels.fragment(
                            account: "m.account_email", messageID: "m.id", label: "'SENT'"))
                    )
                    ORDER BY internal_date DESC, id DESC LIMIT ?
                    """,
                arguments: [account, limit])
            return try rows.map { try Self.messageRow(from: $0, account: account, db: db) }
        }
    }
}
