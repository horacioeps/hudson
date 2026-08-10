import GRDB

/// Reactive twins of Store's one-shot reads. Each method wraps the exact
/// same SELECT as its one-shot sibling in a `ValueObservation`, so GRDB's
/// automatic region tracking re-runs it only when a table it actually read
/// changes — no manual invalidation, no polling. Because `enqueueMutation`
/// writes `mutation_queue` AND recomputes `thread_rollup` in the SAME
/// transaction (see `MutationQueue.enqueueMutation`), an optimistic triage
/// re-emits `observeInboxThreads`/`observePendingCount` for free, with no
/// separate "notify the UI" step for a caller to remember.
///
/// SwiftUI views (later tasks) consume these as `AsyncSequence`s — one
/// `for await` loop per subscription — rather than polling the one-shot
/// reads on a timer.
extension HudsonDatabase {
    /// Reactive twin of `InboxQuery.inboxThreads` — same SELECT, kept
    /// byte-for-byte aligned so the two never drift. Unlike the one-shot
    /// read, this observes only the FIRST `limit` rows: `ValueObservation`
    /// re-runs its whole closure on every emit, so there's no equivalent of
    /// keyset paging here — a caller paging deeper than `limit` stays on the
    /// one-shot `inboxThreads`.
    public func observeInboxThreads(
        account: String, split: String?, limit: Int
    ) -> AsyncValueObservation<[ThreadRow]> {
        ValueObservation
            .tracking { db -> [ThreadRow] in
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
                sql += " ORDER BY last_message_at DESC, thread_id DESC LIMIT ?"
                arguments += [limit]
                return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.threadRow(from:))
            }
            .values(in: writer)
    }

    /// Reactive twin of `AIStore.threadMessages` — same SELECT, so it
    /// re-emits on any change to `messages`/`message_labels`/`mutation_queue`
    /// that affects this thread's effective label overlay (e.g. marking a
    /// message read/unread).
    public func observeThread(
        threadID: String, account: String
    ) -> AsyncValueObservation<[MessageRow]> {
        ValueObservation
            .tracking { db -> [MessageRow] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM messages WHERE account_email = ? AND thread_id = ?
                        ORDER BY internal_date ASC, id ASC
                        """,
                    arguments: [account, threadID])
                return try rows.map { try Self.messageRow(from: $0, account: account, db: db) }
            }
            .values(in: writer)
    }

    /// Reactive twin of `SplitInbox.splitRules` — same SELECT (via the
    /// shared synchronous `SplitInbox.fetchRules`), so a settings-UI edit to
    /// the rule set (`setSplitRules`) re-emits here immediately.
    public func observeSplitRules(account: String) -> AsyncValueObservation<[SplitRule]> {
        ValueObservation
            .tracking { db in try SplitInbox.fetchRules(account: account, db: db) }
            .values(in: writer)
    }

    /// Live count of not-yet-confirmed local mutations for the account —
    /// drives the "N pending / syncing" indicator. Re-emits on every
    /// `enqueueMutation`/`retireConfirmedMutations`/`dropMutation`, since all
    /// three write `mutation_queue`.
    public func observePendingCount(account: String) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM mutation_queue WHERE account_email = ?",
                    arguments: [account]) ?? 0
            }
            .values(in: writer)
    }
}
