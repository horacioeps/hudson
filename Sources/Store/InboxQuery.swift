import GRDB

/// One row of the inbox list — the ONLY thing `inboxThreads` reads is
/// `thread_rollup`, so listing the inbox never joins or aggregates across
/// `messages`/`message_labels` (M4's headline invariant: zero N+1, zero
/// aggregation at read time — all of that work happened incrementally,
/// ahead of time, in `ThreadRollup`).
public struct ThreadRow: Sendable, Equatable {
    public let threadID: String
    public let lastMessageID: String
    public let subject: String
    public let snippet: String
    public let fromSummary: String
    public let splitKey: String
    public let category: String
    public let lastMessageAt: Int64
    public let messageCount: Int
    public let unread: Bool
    public let inInbox: Bool
    public let hasAttachment: Bool
}

extension HudsonDatabase {
    /// Newest-first inbox list, resolved from ONE index-backed query over
    /// `thread_rollup` — `WHERE account_email = ? AND in_inbox = 1 [AND
    /// split_key = ?] ORDER BY last_message_at DESC, thread_id DESC LIMIT
    /// ?`, served by `index_thread_rollup_on_account_email_in_inbox_last_message_at`
    /// (and the split-scoped sibling index when `split` is given).
    ///
    /// **Overlay-composed for free:** `thread_rollup.in_inbox`/`unread` are
    /// themselves overlay-aware — `ThreadRollup.recomputeThreadFlags`
    /// (Task 2) folds in any pending `mutation_queue` delta when it runs —
    /// and the M3↔M4 seam (`enqueueMutation`/`retireConfirmedMutations`/
    /// `dropMutation` in `MutationQueue.swift`) calls it the moment a
    /// triage action is enqueued or resolved. So an optimistic archive
    /// drops its thread from this list on the very next call, with no
    /// separate recompute step for a caller to remember, and no query here
    /// ever needs to touch `mutation_queue` itself.
    ///
    /// **Keyset-paginated:** `before` is the `(lastMessageAt, threadID)` of
    /// the last row on the previous page. Passing it back in fetches the
    /// NEXT page in the same order via a row-value comparison —
    /// `(last_message_at, thread_id) < (?, ?)` — rather than an `OFFSET`,
    /// so each page is an indexed range seek: cost stays flat as the
    /// caller pages deeper, instead of degrading with a growing offset.
    public func inboxThreads(
        account: String, split: String?, limit: Int,
        before: (lastMessageAt: Int64, threadID: String)? = nil
    ) async throws -> [ThreadRow] {
        try await writer.read { db in
            var sql = """
                SELECT thread_id, last_message_id, subject, snippet, from_summary,
                       split_key, category, last_message_at, message_count,
                       unread, in_inbox, has_attachment
                FROM thread_rollup
                WHERE account_email = ? AND in_inbox = 1
                """
            var arguments: StatementArguments = [account]
            if let split {
                sql += " AND split_key = ?"
                arguments += [split]
            }
            if let before {
                sql += " AND (last_message_at, thread_id) < (?, ?)"
                arguments += [before.lastMessageAt, before.threadID]
            }
            sql += " ORDER BY last_message_at DESC, thread_id DESC LIMIT ?"
            arguments += [limit]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map(Self.threadRow(from:))
        }
    }

    static func threadRow(from row: Row) -> ThreadRow {
        ThreadRow(
            threadID: row["thread_id"], lastMessageID: row["last_message_id"] ?? "",
            subject: row["subject"], snippet: row["snippet"],
            fromSummary: row["from_summary"], splitKey: row["split_key"],
            category: row["category"], lastMessageAt: row["last_message_at"],
            messageCount: row["message_count"], unread: row["unread"],
            inInbox: row["in_inbox"], hasAttachment: row["has_attachment"])
    }
}
