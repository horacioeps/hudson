import GRDB

/// Incremental (O(1)) maintenance of `thread_rollup` — the sole surface the
/// inbox list reads (Task 5). This is the M4 milestone's biggest risk: every
/// entry point here touches exactly ONE thread's row (a primary-key upsert
/// or a bounded scan of that one thread's messages) — never a scan across
/// other threads. A naive full-thread recompute on every applied message
/// would be O(N) per write and O(N²) across a newest-first backfill of a
/// large thread, which would make sync crawl. See `maintainRollup` and
/// `recomputeThreadFlags` for how each avoids that.
enum ThreadRollup {
    /// Upserts the ONE thread's rollup row after `snapshot` has already been
    /// written to `messages`/`message_labels` in the same transaction
    /// (called from `applySnapshotInTransaction`, after its upsert +
    /// `replaceLabels`).
    ///
    /// - `message_count` increments only when `wasInsert` is true — a
    ///   re-applied snapshot for a message the store already has (a later
    ///   history_id for the same id) must not double-count.
    /// - `last_message_at` is `MAX(existing, snapshot.internalDate)`; when
    ///   this snapshot is (at least tied for) the thread's newest, its
    ///   `last_message_id`/`subject`/`snippet` are also written onto the
    ///   rollup.
    /// - `unread`/`in_inbox` are OR-merged forward from the row's prior
    ///   value, but **only on insert**: a brand-new message can only ever
    ///   ADD to what's unread/in-inbox for the thread, so OR-merging is
    ///   always correct there and — critically — is a single indexed upsert
    ///   with no scan, which is what keeps a newest-first backfill of a
    ///   large thread O(1) per message instead of O(N²).
    ///
    ///   An OR-merge can never LOWER a flag, so it is not safe for a
    ///   same-message update (labels may have just dropped UNREAD/INBOX):
    ///   those are left untouched here and handled by the targeted,
    ///   bounded `recomputeThreadFlags` instead — called by
    ///   `applyHistoryChanges`'s `.labels` branch for every label-only
    ///   event, which is exactly where a flag needs to be able to fall.
    static func maintainRollup(
        afterApplying snapshot: MessageSnapshot, wasInsert: Bool, account: String, db: Database
    ) throws {
        let isUnread = snapshot.labelIDs.contains("UNREAD")
        let isInInbox = snapshot.labelIDs.contains("INBOX")
        let countDelta = wasInsert ? 1 : 0

        try db.execute(
            sql: """
                INSERT INTO thread_rollup
                    (account_email, thread_id, last_message_at, last_message_id, subject, snippet,
                     message_count, unread, in_inbox)
                VALUES (:account, :thread, :date, :msgID, :subject, :snippet, :delta, :unread, :inbox)
                ON CONFLICT(account_email, thread_id) DO UPDATE SET
                    last_message_at = MAX(
                        IFNULL(thread_rollup.last_message_at, excluded.last_message_at), excluded.last_message_at),
                    last_message_id = CASE
                        WHEN excluded.last_message_at >= IFNULL(thread_rollup.last_message_at, excluded.last_message_at)
                        THEN excluded.last_message_id ELSE thread_rollup.last_message_id END,
                    subject = CASE
                        WHEN excluded.last_message_at >= IFNULL(thread_rollup.last_message_at, excluded.last_message_at)
                        THEN excluded.subject ELSE thread_rollup.subject END,
                    snippet = CASE
                        WHEN excluded.last_message_at >= IFNULL(thread_rollup.last_message_at, excluded.last_message_at)
                        THEN excluded.snippet ELSE thread_rollup.snippet END,
                    message_count = thread_rollup.message_count + excluded.message_count,
                    unread = CASE WHEN :was_insert
                        THEN (thread_rollup.unread OR excluded.unread) ELSE thread_rollup.unread END,
                    in_inbox = CASE WHEN :was_insert
                        THEN (thread_rollup.in_inbox OR excluded.in_inbox) ELSE thread_rollup.in_inbox END
                """,
            arguments: [
                "account": account, "thread": snapshot.threadID, "date": snapshot.internalDate,
                "msgID": snapshot.id, "subject": snapshot.subject, "snippet": snapshot.snippet,
                "delta": countDelta, "unread": isUnread, "inbox": isInInbox, "was_insert": wasInsert,
            ])
    }

    /// Recomputes `unread`/`in_inbox` for exactly ONE thread from a bounded
    /// scan of that thread's own messages — the targeted recompute
    /// `maintainRollup`'s OR-merge can't provide, since only a full
    /// re-derivation can lower a flag (e.g. the thread's last unread message
    /// just got marked read). Called from `applyHistoryChanges`'s `.labels`
    /// branch for every label-only event.
    ///
    /// Overlay-aware: labels are read as *effective* — canonical
    /// `message_labels` with pending `mutation_queue` deltas applied
    /// (add ∪ canonical, minus pending removes) — the same composition
    /// `StoreReads.messageRow` uses, so a pending optimistic archive/read is
    /// reflected here immediately (the M3↔M4 overlay seam).
    static func recomputeThreadFlags(threadID: String, account: String, db: Database) throws {
        let unread = try effectiveLabelPresentInThread(
            label: "UNREAD", threadID: threadID, account: account, db: db)
        let inInbox = try effectiveLabelPresentInThread(
            label: "INBOX", threadID: threadID, account: account, db: db)
        try db.execute(
            sql: """
                UPDATE thread_rollup SET unread = ?, in_inbox = ?
                WHERE account_email = ? AND thread_id = ?
                """,
            arguments: [unread, inInbox, account, threadID])
    }

    /// Whether any message in the ONE given thread effectively carries
    /// `label` — effective = (canonical ∪ pending adds) − pending removes,
    /// mirroring `StoreReads.messageRow`'s overlay composition. Scoped to
    /// `thread_id = :thread` throughout, so this is a bounded scan of that
    /// thread's messages only, never other threads.
    private static func effectiveLabelPresentInThread(
        label: String, threadID: String, account: String, db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM messages m
                    WHERE m.account_email = :account AND m.thread_id = :thread
                    AND EXISTS (
                        SELECT 1 FROM (
                            SELECT label_id FROM message_labels
                            WHERE account_email = :account AND message_id = m.id
                            UNION
                            SELECT label_id FROM mutation_queue
                            WHERE account_email = :account AND message_id = m.id AND op = 'add'
                        ) AS present
                        WHERE label_id = :label
                        AND label_id NOT IN (
                            SELECT label_id FROM mutation_queue
                            WHERE account_email = :account AND message_id = m.id AND op = 'remove'
                        )
                    )
                )
                """,
            arguments: ["account": account, "thread": threadID, "label": label]) ?? false
    }
}
