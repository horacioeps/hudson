import Foundation
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
    /// - `split_key`/`category` (Task 7) ARE fully derivable from a bare
    ///   `MessageSnapshot` (its `fromLine`/`labelIDs`, via
    ///   `SplitInbox.computeSplit`) — unlike `has_attachment`, so they need
    ///   no `:was_insert` gate and instead follow the SAME tied-or-newer
    ///   rule as `subject`/`snippet`: whichever applied snapshot is the
    ///   thread's current newest (insert OR update) determines the
    ///   rollup's split/category, so a routine re-apply of the newest
    ///   message (label change, resync) keeps them correctly in sync with
    ///   its current label set.
    ///
    ///   `rules` is the account's ordered `split_rules`, loaded ONCE by the
    ///   caller (`StoreWrites`'s batch entry points load it once per batch
    ///   and thread it through; single-message callers load it once per
    ///   call) — never re-queried per message inside a loop here.
    static func maintainRollup(
        afterApplying snapshot: MessageSnapshot, wasInsert: Bool, account: String, db: Database,
        rules: [SplitRule]
    ) throws {
        let isUnread = snapshot.labelIDs.contains("UNREAD")
        let isInInbox = snapshot.labelIDs.contains("INBOX")
        let countDelta = wasInsert ? 1 : 0
        // `listID` is always nil here — see `SplitInbox.computeSplit`'s doc
        // comment: `MessageSnapshot` doesn't carry `List-Id` yet.
        let split = SplitInbox.computeSplit(
            fromLine: snapshot.fromLine, listID: nil, categoryLabels: snapshot.labelIDs, rules: rules)

        // `from_summary`: append-dedup, computed in Swift (not pure SQL —
        // dedup against a variable-length ", "-joined list isn't a clean
        // SQL expression). Only on a genuinely NEW message (`wasInsert`)
        // does a sender ever get ADDED — see `appendSenderDisplayName`'s
        // doc comment for why this stays O(1). The read below is a single
        // indexed point lookup by this row's OWN primary key
        // (`account_email`, `thread_id`) — not a scan of the thread's
        // messages or of other threads, so it doesn't cost more as the
        // thread grows and doesn't reintroduce the O(N²) this file guards
        // against. On an UPDATE (`!wasInsert`) this is skipped entirely:
        // the SQL below's `CASE WHEN :was_insert` keeps the existing
        // `thread_rollup.from_summary` untouched, so `fromSummary` here is
        // an unused placeholder for that path.
        let displayName = senderDisplayName(fromLine: snapshot.fromLine)
        var fromSummary = displayName
        if wasInsert {
            let existing = try String.fetchOne(
                db,
                sql: "SELECT from_summary FROM thread_rollup WHERE account_email = ? AND thread_id = ?",
                arguments: [account, snapshot.threadID]) ?? ""
            fromSummary = appendSenderDisplayName(displayName, to: existing)
        }

        try db.execute(
            sql: """
                INSERT INTO thread_rollup
                    (account_email, thread_id, last_message_at, last_message_id, subject, snippet,
                     from_summary, split_key, category, message_count, unread, in_inbox, has_attachment)
                VALUES (:account, :thread, :date, :msgID, :subject, :snippet,
                        :from_summary, :split_key, :category, :delta, :unread, :inbox, 0)
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
                    from_summary = CASE WHEN :was_insert THEN :from_summary ELSE thread_rollup.from_summary END,
                    split_key = CASE
                        WHEN (excluded.last_message_at, excluded.last_message_id) >= (
                            IFNULL(thread_rollup.last_message_at, excluded.last_message_at),
                            IFNULL(thread_rollup.last_message_id, excluded.last_message_id))
                        THEN excluded.split_key ELSE thread_rollup.split_key END,
                    category = CASE
                        WHEN (excluded.last_message_at, excluded.last_message_id) >= (
                            IFNULL(thread_rollup.last_message_at, excluded.last_message_at),
                            IFNULL(thread_rollup.last_message_id, excluded.last_message_id))
                        THEN excluded.category ELSE thread_rollup.category END,
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
                "from_summary": fromSummary, "split_key": split.splitKey, "category": split.category,
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
    ///
    /// `split_key`/`category` (Task 7) are re-derived here too, from the
    /// surviving newest message's `from_line` and (canonical, non-overlay —
    /// matching `maintainRollup`) labels — a deletion can change who the
    /// newest message is, so its split/category must be recomputed
    /// alongside `subject`/`snippet`/`last_message_id`, not just carried
    /// over. `rules` defaults to `nil`, which fetches the account's
    /// `split_rules` once right here — fine for this function's normal
    /// callers (`.deleted`/`deleteVanishedMessage`), which run per
    /// deletion, not per message, so there's no batching concern like the
    /// insert/update path. A caller iterating many threads for the SAME
    /// account in one pass (the v5 migration backfill, `Migrations.swift`'s
    /// `runFromSummaryBackfill`) can instead fetch rules once and pass them
    /// through here, the same `splitRules`-threading pattern
    /// `applySnapshotInTransaction`/`maintainRollup` already use.
    ///
    /// `from_summary` is likewise fully rebuilt here — this is the
    /// AUTHORITATIVE rebuild, unlike `maintainRollup`'s append-only upsert
    /// (which can add a sender but can never express a removal): a deleted
    /// message may have been a sender's only message in the thread, so its
    /// name must be able to drop out of the summary. Rebuilt from the
    /// survivors' DISTINCT `senderDisplayName`s, oldest → newest (the order
    /// senders first joined the thread), same cap/overflow rule as
    /// `appendSenderDisplayName` (drop the oldest names first). Already an
    /// O(thread) scan like the rest of this function — this adds a fixed
    /// constant, not a new order of growth.
    static func recomputeThreadRollup(
        threadID: String, account: String, db: Database, rules: [SplitRule]? = nil
    ) throws {
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
                SELECT id, subject, snippet, internal_date, has_attachment, from_line FROM messages
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
        let fromLine: String = newest["from_line"]

        let unread = try effectiveLabelPresentInThread(
            label: "UNREAD", threadID: threadID, account: account, db: db)
        let inInbox = try effectiveLabelPresentInThread(
            label: "INBOX", threadID: threadID, account: account, db: db)

        // `from_summary` rebuild — see this function's doc comment. Oldest
        // → newest so distinct names are collected in join order, then
        // capped from the front (drop the oldest) to match
        // `appendSenderDisplayName`'s overflow rule.
        let survivorFromLines = try String.fetchAll(
            db,
            sql: """
                SELECT from_line FROM messages
                WHERE account_email = ? AND thread_id = ?
                ORDER BY internal_date ASC, id ASC
                """,
            arguments: [account, threadID])
        var distinctSenderNames: [String] = []
        for line in survivorFromLines {
            let name = senderDisplayName(fromLine: line)
            guard !name.isEmpty, !distinctSenderNames.contains(name) else { continue }
            distinctSenderNames.append(name)
        }
        if distinctSenderNames.count > fromSummaryCap {
            distinctSenderNames.removeFirst(distinctSenderNames.count - fromSummaryCap)
        }
        let fromSummary = distinctSenderNames.joined(separator: ", ")

        // Canonical labels only (not overlay) — matches `maintainRollup`'s
        // split/category derivation, which is likewise never overlay-aware.
        let labelIDs = try String.fetchAll(
            db, sql: "SELECT label_id FROM message_labels WHERE account_email = ? AND message_id = ?",
            arguments: [account, lastMessageID])
        let resolvedRules = try rules ?? SplitInbox.fetchRules(account: account, db: db)
        let split = SplitInbox.computeSplit(
            fromLine: fromLine, listID: nil, categoryLabels: labelIDs, rules: resolvedRules)

        try db.execute(
            sql: """
                INSERT INTO thread_rollup
                    (account_email, thread_id, last_message_at, last_message_id, subject, snippet,
                     from_summary, split_key, category, message_count, unread, in_inbox, has_attachment)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_email, thread_id) DO UPDATE SET
                    last_message_at = excluded.last_message_at,
                    last_message_id = excluded.last_message_id,
                    subject = excluded.subject,
                    snippet = excluded.snippet,
                    from_summary = excluded.from_summary,
                    split_key = excluded.split_key,
                    category = excluded.category,
                    message_count = excluded.message_count,
                    unread = excluded.unread,
                    in_inbox = excluded.in_inbox,
                    has_attachment = excluded.has_attachment
                """,
            arguments: [
                account, threadID, lastMessageAt, lastMessageID, subject, snippet, fromSummary,
                split.splitKey, split.category, count, unread, inInbox, hasAttachment,
            ])
    }

    /// Recomputes `split_key`/`category` for exactly ONE thread from its
    /// CURRENT newest message. Needed because `maintainRollup`'s
    /// tied-or-newer write only ever runs when a FULL `MessageSnapshot`
    /// reaches it — a `.labels`-only history event (Gmail reporting a
    /// `CATEGORY_*` move, e.g. the user dragging a message between tabs,
    /// or the classifier revising already-delivered mail) never does, so
    /// without this the rollup's split/category would silently stay
    /// whatever they were the last time a full snapshot touched the
    /// thread — for a single-message thread, potentially forever. Called
    /// from `applyHistoryChanges`'s `.labels` branch, deduped once per
    /// affected thread across the batch (mirrors the `.added`-update-path
    /// recompute's dedup — see that function's comment).
    ///
    /// Bounded: ONE newest-message lookup (the same `(account_email,
    /// thread_id, internal_date)`-indexed query `recomputeThreadRollup`
    /// uses) plus that one message's own (canonical, non-overlay) labels —
    /// never a scan of other threads or of this thread's other messages.
    /// `rules` is the account's ordered `split_rules`, loaded ONCE per
    /// batch by the caller — not re-fetched here.
    static func recomputeThreadSplit(
        threadID: String, account: String, rules: [SplitRule], db: Database
    ) throws {
        guard let newest = try Row.fetchOne(
            db,
            sql: """
                SELECT id, from_line FROM messages
                WHERE account_email = ? AND thread_id = ?
                ORDER BY internal_date DESC, id DESC LIMIT 1
                """,
            arguments: [account, threadID]
        ) else { return }
        let newestID: String = newest["id"]
        let fromLine: String = newest["from_line"]
        // Canonical labels only (not overlay) — matches `maintainRollup`/
        // `recomputeThreadRollup`'s split derivation, which is likewise
        // never overlay-aware.
        let labelIDs = try String.fetchAll(
            db,
            sql: "SELECT label_id FROM message_labels WHERE account_email = ? AND message_id = ?",
            arguments: [account, newestID])
        let split = SplitInbox.computeSplit(
            fromLine: fromLine, listID: nil, categoryLabels: labelIDs, rules: rules)
        try db.execute(
            sql: """
                UPDATE thread_rollup SET split_key = ?, category = ?
                WHERE account_email = ? AND thread_id = ?
                """,
            arguments: [split.splitKey, split.category, account, threadID])
    }

    /// Whether any message in the ONE given thread effectively carries
    /// `label` — effective = (canonical ∪ pending adds) − pending removes,
    /// the shared `EffectiveLabels.fragment` overlay composition. Scoped to
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
                        \(EffectiveLabels.fragment(account: ":account", messageID: "m.id", label: ":label"))
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

    // MARK: - from_summary (Task 9b: sender display names, append-dedup)

    /// Max distinct sender names kept in `from_summary` — bounds both the
    /// column's length and (via the membership check in
    /// `appendSenderDisplayName`) the per-message dedup cost, independent
    /// of thread size. 3 matches a Superhuman-style compact preview (e.g.
    /// "Ada, Bob, You") — enough to name a thread's recent participants
    /// without the column growing unbounded on a huge thread.
    static let fromSummaryCap = 3

    /// Appends `displayName` to `existing` (a `", "`-joined list) unless
    /// already present, keeping at most `fromSummaryCap` distinct names —
    /// on overflow the OLDEST name is dropped, so the string always
    /// reflects the most recently-seen distinct senders. A bounded string
    /// op — split/contains/join over at most `fromSummaryCap + 1` short
    /// names — independent of thread size, which is what keeps
    /// `maintainRollup`'s insert path O(1) instead of scanning the
    /// thread's other messages to find its distinct senders.
    static func appendSenderDisplayName(_ displayName: String, to existing: String) -> String {
        guard !displayName.isEmpty else { return existing }
        guard !existing.isEmpty else { return displayName }
        var names = existing.components(separatedBy: ", ")
        guard !names.contains(displayName) else { return existing }
        names.append(displayName)
        if names.count > fromSummaryCap {
            names.removeFirst(names.count - fromSummaryCap)
        }
        return names.joined(separator: ", ")
    }

    /// Extracts a compact, human-readable sender label from an RFC 5322
    /// `From` header value for `from_summary`: the display name if the
    /// header has a `Display Name <email>` form (surrounding double-quotes
    /// stripped, whitespace trimmed), else the email's local-part (`ada`
    /// from `ada@example.com`), else the raw value trimmed as-is.
    ///
    /// Pure and total — `from_line` is untrusted (sender-controlled mail
    /// headers reach this via `MessageSnapshot.fromLine`/`messages.from_line`),
    /// so this never throws or crashes on malformed input; worst case it
    /// echoes back a fragment of the raw string. Callers needing a
    /// display-safe string for terminal output still sanitize separately
    /// (Task 9's CLI print path) — this only decides WHICH substring to
    /// keep, not how to render it safely.
    static func senderDisplayName(fromLine: String) -> String {
        let trimmed = fromLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let open = trimmed.firstIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let namePart = trimmed[trimmed.startIndex..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let unquotedName = unquoted(namePart)
            if !unquotedName.isEmpty { return unquotedName }
            let email = trimmed[trimmed.index(after: open)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return localPart(of: email)
        }
        return localPart(of: trimmed)
    }

    /// Strips one layer of matching double-quotes (an RFC 5322
    /// quoted-string display name, e.g. `"Ada Lovelace"`), if present.
    private static func unquoted(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `ada` from `ada@example.com`; the whole string unchanged if there's
    /// no `@`.
    private static func localPart(of email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        return String(email[email.startIndex..<at])
    }
}
