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
    ///   this snapshot is the thread's newest, its
    ///   `last_message_id`/`subject`/`snippet` are also written onto the
    ///   rollup. "Newest" ties break on `last_message_id DESC`, matching
    ///   the `ORDER BY internal_date DESC, id DESC` the v3 bulk build uses
    ///   to pick a thread's newest message — so incrementally-maintained
    ///   rollups and a from-scratch rebuild always agree on ties.
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
    /// - `has_attachment` (Task 5) is NOT snapshot-stable the way
    ///   `subject`/`snippet` are — a bare `MessageSnapshot` never carries
    ///   attachment info, so this path always writes a literal `0`
    ///   (`excluded.has_attachment`) rather than the message's real value
    ///   (only `format: "full"` body hydration knows that, via `saveBody`
    ///   → `maintainHasAttachment`). That makes the tied-or-newer check
    ///   `subject`/`snippet` use UNSAFE here on its own: re-applying an
    ///   already-hydrated newest message as an UPDATE (a routine label
    ///   change, a duplicate history event, a stale-historyId resync) ties
    ///   on the newest-check and would silently blow the real `true` back
    ///   to `0` with no self-heal (`messageIDsNeedingBodies` never
    ///   re-selects an already-hydrated message). So — like `unread`/
    ///   `in_inbox` below — this is additionally gated on `:was_insert`:
    ///   only a genuinely NEW newest message (insert) gets to reset the
    ///   flag to "unknown, pending hydration"; an update never touches it.
    ///   Fix round 1 (reviewer-caught Critical).
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
                     message_count, unread, in_inbox, has_attachment)
                VALUES (:account, :thread, :date, :msgID, :subject, :snippet, :delta, :unread, :inbox, 0)
                ON CONFLICT(account_email, thread_id) DO UPDATE SET
                    last_message_at = MAX(
                        IFNULL(thread_rollup.last_message_at, excluded.last_message_at), excluded.last_message_at),
                    last_message_id = CASE
                        WHEN (excluded.last_message_at, excluded.last_message_id) >= (
                            IFNULL(thread_rollup.last_message_at, excluded.last_message_at),
                            IFNULL(thread_rollup.last_message_id, excluded.last_message_id))
                        THEN excluded.last_message_id ELSE thread_rollup.last_message_id END,
                    subject = CASE
                        WHEN (excluded.last_message_at, excluded.last_message_id) >= (
                            IFNULL(thread_rollup.last_message_at, excluded.last_message_at),
                            IFNULL(thread_rollup.last_message_id, excluded.last_message_id))
                        THEN excluded.subject ELSE thread_rollup.subject END,
                    snippet = CASE
                        WHEN (excluded.last_message_at, excluded.last_message_id) >= (
                            IFNULL(thread_rollup.last_message_at, excluded.last_message_at),
                            IFNULL(thread_rollup.last_message_id, excluded.last_message_id))
                        THEN excluded.snippet ELSE thread_rollup.snippet END,
                    has_attachment = CASE
                        WHEN :was_insert AND (excluded.last_message_at, excluded.last_message_id) >= (
                            IFNULL(thread_rollup.last_message_at, excluded.last_message_at),
                            IFNULL(thread_rollup.last_message_id, excluded.last_message_id))
                        THEN excluded.has_attachment ELSE thread_rollup.has_attachment END,
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

    /// Fully rebuilds ONE thread's rollup row from its current surviving
    /// messages — `message_count`, the newest surviving message's
    /// `last_message_id`/`subject`/`snippet`/`last_message_at`, and
    /// overlay-aware `unread`/`in_inbox` — or deletes the rollup row
    /// entirely if the thread has no messages left.
    ///
    /// Called after a `.deleted` history event: unlike `maintainRollup`'s
    /// O(1) incremental upsert (correct for insert/update, where a message
    /// is only ever ADDED), a deletion can't be expressed as an
    /// incremental delta — the count must drop, and if the deleted message
    /// was the thread's newest, a new newest has to be re-derived from the
    /// survivors. Still bounded to the ONE thread's own messages throughout
    /// (the same indexed `thread_id` scan `recomputeThreadFlags` and the
    /// v3 bulk build use) — never touches other threads.
    static func recomputeThreadRollup(threadID: String, account: String, db: Database) throws {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM messages WHERE account_email = ? AND thread_id = ?",
            arguments: [account, threadID]) ?? 0

        guard count > 0 else {
            try db.execute(
                sql: "DELETE FROM thread_rollup WHERE account_email = ? AND thread_id = ?",
                arguments: [account, threadID])
            return
        }

        // Newest-message tie-break matches `maintainRollup`/the bulk build:
        // internal_date DESC, id DESC.
        guard let newest = try Row.fetchOne(
            db,
            sql: """
                SELECT id, subject, snippet, internal_date, has_attachment FROM messages
                WHERE account_email = ? AND thread_id = ?
                ORDER BY internal_date DESC, id DESC LIMIT 1
                """,
            arguments: [account, threadID]
        ) else { return }
        let lastMessageAt: Int64 = newest["internal_date"]
        let lastMessageID: String = newest["id"]
        let subject: String = newest["subject"]
        let snippet: String = newest["snippet"]
        // Unlike `maintainRollup` (which never sees this field on a bare
        // snapshot), the survivor's `has_attachment` is already known here
        // — `messages.has_attachment` is set by hydration independently of
        // this rebuild, so it's read straight from the row rather than
        // reset to "unknown".
        let hasAttachment: Bool = newest["has_attachment"]

        let unread = try effectiveLabelPresentInThread(
            label: "UNREAD", threadID: threadID, account: account, db: db)
        let inInbox = try effectiveLabelPresentInThread(
            label: "INBOX", threadID: threadID, account: account, db: db)

        try db.execute(
            sql: """
                INSERT INTO thread_rollup
                    (account_email, thread_id, last_message_at, last_message_id, subject, snippet,
                     message_count, unread, in_inbox, has_attachment)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_email, thread_id) DO UPDATE SET
                    last_message_at = excluded.last_message_at,
                    last_message_id = excluded.last_message_id,
                    subject = excluded.subject,
                    snippet = excluded.snippet,
                    message_count = excluded.message_count,
                    unread = excluded.unread,
                    in_inbox = excluded.in_inbox,
                    has_attachment = excluded.has_attachment
                """,
            arguments: [
                account, threadID, lastMessageAt, lastMessageID, subject, snippet,
                count, unread, inInbox, hasAttachment,
            ])
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

    /// Refreshes `thread_rollup.has_attachment` from ONE message's own
    /// flag — but only when that message is still the thread's current
    /// newest (`last_message_id`); `has_attachment` mirrors "the last
    /// message" (same semantics as `subject`/`snippet`), not an aggregate
    /// across the thread. Called by `StoreBodies.saveBody` right after it
    /// sets `messages.has_attachment`, since real hydration is the only
    /// place the true value becomes known (`maintainRollup` never sees it
    /// — see its doc comment). Hydration order is independent of arrival
    /// order, so an older message finishing hydration after a newer one
    /// has already arrived must not leak its flag onto a rollup row it's
    /// no longer the newest of — the `last_message_id` equality guard is
    /// what prevents that; a stale/superseded message's update is a
    /// harmless no-op (zero rows match).
    static func maintainHasAttachment(
        messageID: String, hasAttachment: Bool, account: String, db: Database
    ) throws {
        guard let threadID = try String.fetchOne(
            db, sql: "SELECT thread_id FROM messages WHERE account_email = ? AND id = ?",
            arguments: [account, messageID]
        ) else { return }
        try db.execute(
            sql: """
                UPDATE thread_rollup SET has_attachment = ?
                WHERE account_email = ? AND thread_id = ? AND last_message_id = ?
                """,
            arguments: [hasAttachment, account, threadID, messageID])
    }
}
