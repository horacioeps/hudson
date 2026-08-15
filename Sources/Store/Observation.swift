import GRDB

/// Everything the first-launch progress indicator needs, in one value.
///
/// Deliberately carries raw numbers and NOT a percentage: the ratchet (a bar
/// must never run backwards) and the ceiling (never claim "almost done" on an
/// estimate) are presentation decisions that belong to the view model, which
/// is also the only layer that knows what it showed last. Store's job is to
/// report what is true right now.
public struct BackfillProgress: Sendable, Equatable {
    /// `pending` | `listing` | `complete`, straight from `accounts`.
    public let state: String
    /// Live windowed `COUNT(*)` of stored messages — the numerator.
    /// Deliberately an exact count rather than `backfilled_count`, which
    /// accumulates forever, counts updates as additions, and is never reset
    /// when a backfill restarts.
    public let stored: Int
    /// Sticky first-page `resultSizeEstimate` for this run; `nil` before the
    /// first page returns.
    public let totalEstimate: Int?
    /// Windowed count when this run started; `nil` until seeded.
    public let countBaseline: Int?

    public init(state: String, stored: Int, totalEstimate: Int?, countBaseline: Int?) {
        self.state = state
        self.stored = stored
        self.totalEstimate = totalEstimate
        self.countBaseline = countBaseline
    }

    /// Whether backfill still has work to do. Driven by persisted STATE, never
    /// by comparing `stored` to `totalEstimate` — a page whose messages 404
    /// between `list` and `get` is skipped without ever incrementing `stored`
    /// (see `SyncEngine.logSkippedMessage`), so an arithmetic completion test
    /// would hang below 100% forever on a mailbox with any deleted mail.
    public var isRunning: Bool { state != "complete" }

    /// Whether the seeds for this run exist yet. `false` in the window between
    /// a restart clearing them and the next first page re-seeding them —
    /// during which `stored` may already reflect a full mailbox, so callers
    /// that phrase a count ("N so far") must not speak until this is `true`.
    public var isSeeded: Bool { countBaseline != nil }

    /// Whether this run is a genuine first download rather than a re-list of
    /// mail already on disk. Only a first download gets a determinate bar;
    /// see `backfill_count_baseline`'s doc comment in `Migrations.swift`.
    ///
    /// Strictly `== 0`, so an unseeded run (`nil`) is NOT mistaken for a fresh
    /// one — `nil` means "we don't know yet", and a fresh account is seeded
    /// with an explicit `0` by `SyncEngine.backfill`.
    public var isFirstDownload: Bool { countBaseline == 0 }
}

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

    /// Live backfill progress for the first-launch indicator (migration `v11`).
    ///
    /// `windowStart` is the caller's window boundary in ms since epoch — the
    /// SAME boundary `SyncEngine.backfillQuery` turns into its Gmail `after:`
    /// filter, supplied by the caller via
    /// `SyncEngine.backfillWindowStartMilliseconds` so Store stays ignorant of
    /// the sync policy. Counting a different window than the run lists would
    /// make the numerator and denominator describe different sets.
    ///
    /// Re-emits on the existing per-page backfill commit (`applySnapshots` +
    /// `updateBackfill` land together), so the bar advances a page at a time
    /// with no polling and no new sync path. A pass that THROWS writes
    /// nothing, so no emission arrives and the last honest value stands —
    /// which is why the view model must seed its own initial state
    /// synchronously rather than waiting for a first emission that a broken
    /// network never produces.
    ///
    /// `removeDuplicates` because hydration and triage also write `messages`
    /// and `accounts`; without it every body fetch would re-emit an identical
    /// value and churn the UI during the very phase this exists to smooth.
    public func observeBackfillProgress(
        account: String, windowStart: Int64
    ) -> AsyncValueObservation<BackfillProgress> {
        ValueObservation
            .tracking { db -> BackfillProgress in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT backfill_state, backfill_total_estimate, backfill_count_baseline
                        FROM accounts WHERE email = ?
                        """,
                    arguments: [account])
                // No account row (disconnected mid-observation) reads as
                // "nothing to do" rather than throwing — the subscription is
                // torn down moments later either way, and a thrown error here
                // would surface as a failed stream the UI has no use for.
                let stored = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM messages
                        WHERE account_email = ? AND internal_date >= ?
                        """,
                    arguments: [account, windowStart]) ?? 0
                return BackfillProgress(
                    state: row?["backfill_state"] ?? "complete",
                    stored: stored,
                    totalEstimate: row?["backfill_total_estimate"],
                    countBaseline: row?["backfill_count_baseline"])
            }
            .removeDuplicates()
            .values(in: writer)
    }

    /// Live count of unread threads across the WHOLE inbox (every split), for
    /// the sidebar's "Inbox" badge. Deliberately NOT filtered by `split_key`:
    /// the badge is a mailbox-wide total, so it must stay constant as the user
    /// switches the inbox list's split tabs — unlike `observeInboxThreads`,
    /// whose row set (and any count derived from it) is scoped to the active
    /// split. Re-emits whenever a triage flips a thread's `unread`/`in_inbox`.
    public func observeInboxUnreadCount(account: String) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM thread_rollup
                        WHERE account_email = ? AND in_inbox = 1 AND unread = 1
                        """,
                    arguments: [account]) ?? 0
            }
            .values(in: writer)
    }
}
