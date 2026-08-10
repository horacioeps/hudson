import Foundation
import GRDB
import OSLog

/// Store-layer log, scoped here since Store imports neither GmailKit (home of
/// the shared `Log` enum) nor networking. Content-free per spec §9.1: never
/// logs message ids or content, only that an apply error was contained.
private let storeLog = Logger(subsystem: "com.hudson.core", category: "store")

extension HudsonDatabase {
    /// Writes a snapshot through the §4.2 version guard. Inside one
    /// transaction: tombstone check → history_id comparison → upsert.
    public func applySnapshot(
        _ snapshot: MessageSnapshot, account: String
    ) async throws -> SnapshotOutcome {
        try await writer.write { db in
            let result = try Self.applySnapshotInTransaction(snapshot, account: account, db: db)
            if result.outcome == .applied && !result.wasInsert {
                // A same-message UPDATE's snapshot may have dropped
                // UNREAD/INBOX; `maintainRollup`'s OR-merge can't lower
                // those (see its doc comment), so this single targeted,
                // bounded (one thread) recompute closes the gap. This is
                // the routine path after a cursor-expiry re-list
                // (SyncEngine's 404 branch resets backfill, which then
                // re-applies every already-known message as an update) —
                // without this, archived/read threads would stay stuck in
                // the inbox as unread until an unrelated `.labels` event
                // happened to touch them.
                try ThreadRollup.recomputeThreadFlags(threadID: snapshot.threadID, account: account, db: db)
            }
            return result.outcome
        }
    }

    /// Applies a page of snapshots in ONE transaction, each guarded by a
    /// SAVEPOINT so a single failing/stale row rolls back only itself. Cutting
    /// commits from per-message to per-page is the load-bearing control against
    /// the SwiftUI ValueObservation storm during the ~6h backfill (architecture M3).
    public func applySnapshots(
        _ snapshots: [MessageSnapshot], account: String
    ) async throws -> Int {
        try await writer.write { db in
            var applied = 0
            // Split rules are loaded ONCE for the whole batch (not
            // re-queried per message) and threaded through
            // `applySnapshotInTransaction` → `ThreadRollup.maintainRollup` —
            // this is the actual backfill/re-list hot path (one commit per
            // page of many messages), so this is where a per-message rules
            // re-query would matter.
            let splitRules = try SplitInbox.fetchRules(account: account, db: db)
            // Batch-deduped, not per-message: an UPDATE's rollup flags can
            // only be correctly lowered by a bounded per-thread recompute
            // (see `applySnapshot`), but running that recompute inside the
            // loop — once per updated message — would cost O(thread size)
            // PER message, i.e. O(N²) across a large-thread re-list (this is
            // exactly the cursor-expiry 404 path: backfill resets and
            // re-`getMessage`s every already-known message as an update).
            // Collecting the distinct touched thread ids and recomputing
            // each ONCE after the loop keeps the whole batch O(total
            // messages) — inserts still take the O(1) OR-merge path in
            // `maintainRollup` and never enter this set at all.
            var updatedThreadIDs = Set<String>()
            for snapshot in snapshots {
                do {
                    try db.execute(sql: "SAVEPOINT s")
                    let result = try Self.applySnapshotInTransaction(
                        snapshot, account: account, db: db, splitRules: splitRules)
                    try db.execute(sql: "RELEASE s")
                    if result.outcome == .applied {
                        applied += 1
                        if !result.wasInsert {
                            updatedThreadIDs.insert(snapshot.threadID)
                        }
                    }
                } catch {
                    try db.execute(sql: "ROLLBACK TO s")
                    try db.execute(sql: "RELEASE s")
                    // Never silent: a genuine bad-data error during the ~6h
                    // backfill must be visible, even though it's contained to
                    // this one message. No id/content logged (spec §9.1).
                    storeLog.warning("applySnapshots: skipped a message on apply error")
                }
            }
            for threadID in updatedThreadIDs {
                try ThreadRollup.recomputeThreadFlags(threadID: threadID, account: account, db: db)
            }
            return applied
        }
    }

    /// Applies history changes in order, in ONE transaction, WITHOUT
    /// touching the stored cursor. Multi-page pollers (spec §4.3) must call
    /// this per page and commit the cursor exactly once, via `advanceCursor`,
    /// after the last page — Gmail reports the *current mailbox* historyId
    /// on every page (not "as of this page"), so committing it per page
    /// would jump the cursor to its final value while later pages are still
    /// unapplied; a crash between pages would then silently lose them (the
    /// M2-review-deferred crash-window bug this split exists to fix). A
    /// crash before the caller's `advanceCursor` leaves the cursor at its
    /// old value, so the next pass's re-poll simply re-applies from there —
    /// safe because of the §4.2 version guard.
    ///
    /// Returns ids of label events targeting unknown, non-tombstoned
    /// messages: these must be hydrated by the caller — a `.labels` event
    /// alone can't materialize a message row (no thread/subject/snippet/etc.),
    /// so without hydration the message would stay permanently missing from
    /// the store rather than merely converging slower (spec §4.1).
    public func applyHistoryChanges(
        _ changes: [HistoryChange], account: String
    ) async throws -> [String] {
        try await writer.write { db in
            var unknownIDs: [String] = []
            // Loaded once per page, same rationale as `applySnapshots` —
            // shared by every `.added` change below.
            let splitRules = try SplitInbox.fetchRules(account: account, db: db)
            // Same batch-dedup as `applySnapshots` — see its comment.
            // `.added` updates (wasInsert == false) AND `.labels` events
            // both need `recomputeThreadFlags` (unread/in_inbox can only be
            // LOWERED by that bounded per-thread recompute — never by
            // `maintainRollup`'s insert-only OR-merge), so they share this
            // ONE set: `recomputeThreadFlags` is idempotent, so a thread
            // touched by both still gets recomputed exactly once, post-loop,
            // instead of once per `.labels` event (Fix wave 2 — a thread
            // with K label events in one batch previously recomputed K
            // times, each a bounded-but-real scan of that thread's M
            // messages, i.e. O(K×M) for the batch; deferred+deduped here
            // like `.added` already was). `.added` inserts take
            // `maintainRollup`'s O(1) OR-merge path and never enter this
            // set at all.
            var flagsRecomputeThreadIDs = Set<String>()
            // `.labels` events' split/category refresh IS deduped, unlike
            // unread/in_inbox above: a thread with several `.labels` events
            // in one batch (all touching the same thread) would otherwise
            // redo the newest-message split lookup once per event instead
            // of once for the batch. Collected here, applied once per
            // unique thread after the loop — see `recomputeThreadSplit`.
            var splitRefreshThreadIDs = Set<String>()
            // `.deleted` events' rollup rebuild — kept in its OWN set,
            // separate from `flagsRecomputeThreadIDs`/`splitRefreshThreadIDs`
            // above, because `recomputeThreadRollup` is a strictly HEAVIER,
            // superseding recompute (full survivor from_line fetch + Swift
            // dedup, count/newest re-derivation — not just unread/in_inbox
            // or split/category). Deferred and deduped for the identical
            // reason: K deletes on one large thread previously ran this
            // heavy rebuild K times inline — O(K×M) for the batch, and the
            // heaviest of the three (this is the one that blocks triage
            // inside the write transaction against the 5s busy timeout).
            // Reconciled against the two lighter sets after the loop below.
            var deletedThreadIDs = Set<String>()
            for change in changes {
                switch change.kind {
                case .added(let snapshot):
                    let result = try Self.applySnapshotInTransaction(
                        snapshot, account: account, db: db, splitRules: splitRules)
                    if result.outcome == .applied && !result.wasInsert {
                        flagsRecomputeThreadIDs.insert(snapshot.threadID)
                    }
                case .deleted(let id):
                    // thread_id fetched BEFORE the delete — needed to
                    // rebuild (or drop) that thread's rollup row afterward.
                    // A deletion isn't expressible as an incremental delta
                    // (count must drop, and the deleted message may have
                    // been the thread's newest), so this thread is queued
                    // for the full per-thread rebuild post-loop rather than
                    // `maintainRollup`. `AIArtifacts.purge` below (Task 8)
                    // purges any cached AI artifact this message fed, in
                    // the same transaction.
                    let threadID = try String.fetchOne(
                        db,
                        sql: "SELECT thread_id FROM messages WHERE account_email = ? AND id = ?",
                        arguments: [account, id])
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO tombstones (account_email, message_id) VALUES (?, ?)",
                        arguments: [account, id])
                    try db.execute(
                        sql: "DELETE FROM messages WHERE account_email = ? AND id = ?",
                        arguments: [account, id])
                    try FTSIndex.deleteIndex(messageID: id, account: account, db: db)
                    try AIArtifacts.purge(sourceMessageID: id, account: account, db: db)
                    if let threadID {
                        deletedThreadIDs.insert(threadID)
                    }
                case .labels(let id, let historyID, let labelIDs):
                    let exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE account_email = ? AND id = ?)",
                        arguments: [account, id]) ?? false
                    guard exists else {
                        // A tombstoned id is known-deleted, not unknown — don't
                        // hand it back for hydration (it would just 404 forever).
                        let tombstoned = try Bool.fetchOne(
                            db,
                            sql: "SELECT EXISTS(SELECT 1 FROM tombstones WHERE account_email = ? AND message_id = ?)",
                            arguments: [account, id]) ?? false
                        if !tombstoned && !unknownIDs.contains(id) {
                            unknownIDs.append(id)
                        }
                        continue
                    }
                    // thread_id fetched alongside history_id (one query) so
                    // the targeted rollup recompute below knows which
                    // thread's row to touch without a second round trip.
                    let messageRow = try Row.fetchOne(
                        db,
                        sql: "SELECT history_id, thread_id FROM messages WHERE account_email = ? AND id = ?",
                        arguments: [account, id])
                    let stored: Int64 = messageRow?["history_id"] ?? 0
                    guard historyID >= stored else { continue }
                    try db.execute(
                        sql: "UPDATE messages SET history_id = ? WHERE account_email = ? AND id = ?",
                        arguments: [historyID, account, id])
                    try Self.replaceLabels(labelIDs, messageID: id, account: account, db: db)
                    // A label-only event can LOWER unread/in_inbox (e.g. the
                    // thread's last unread message just got marked read) —
                    // maintainRollup's insert-time OR-merge can't do that, so
                    // this thread is queued for a targeted, bounded (one
                    // thread) recompute post-loop — see
                    // `flagsRecomputeThreadIDs`'s doc comment above for why
                    // this no longer runs inline here.
                    if let threadID: String = messageRow?["thread_id"] {
                        flagsRecomputeThreadIDs.insert(threadID)
                        splitRefreshThreadIDs.insert(threadID)
                    }
                }
            }
            // `.deleted`'s full rebuild (queued in `deletedThreadIDs`)
            // re-derives unread/in_inbox AND split_key/category from
            // scratch, so it supersedes a flags-only or split-only
            // recompute for the SAME thread — drop those threads from the
            // two lighter sets so each thread gets exactly ONE authoritative
            // post-loop recompute, never two. Safe regardless of event
            // order within the batch: every message/label write above ran
            // inline, in order, so by the time any of these post-loop
            // recomputes run, all three see that thread's fully up-to-date
            // messages/labels — only the ROLLUP recompute itself was
            // deferred.
            for threadID in deletedThreadIDs {
                flagsRecomputeThreadIDs.remove(threadID)
                splitRefreshThreadIDs.remove(threadID)
            }
            for threadID in deletedThreadIDs {
                try ThreadRollup.recomputeThreadRollup(
                    threadID: threadID, account: account, db: db, rules: splitRules)
            }
            for threadID in flagsRecomputeThreadIDs {
                try ThreadRollup.recomputeThreadFlags(threadID: threadID, account: account, db: db)
            }
            for threadID in splitRefreshThreadIDs {
                try ThreadRollup.recomputeThreadSplit(
                    threadID: threadID, account: account, rules: splitRules, db: db)
            }
            return unknownIDs
        }
    }

    /// Advances the stored history cursor — forward-only (`WHERE
    /// history_cursor IS NULL OR history_cursor < newCursor`), so
    /// re-applying an older or equal page after a crash-triggered re-poll
    /// (see `applyHistoryChanges`) can never regress the cursor. §4.3
    /// requires a missing accounts row to fail loudly rather than silently
    /// report success with a stale cursor; the forward-only guard rejecting
    /// an update because the cursor is already caught up is a legitimate
    /// no-op, not that failure, so the two are told apart explicitly.
    public func advanceCursor(to newCursor: Int64, account: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts SET history_cursor = ?
                    WHERE email = ? AND (history_cursor IS NULL OR history_cursor < ?)
                    """,
                arguments: [newCursor, account, newCursor])
            guard db.changesCount == 0 else { return }
            let exists = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE email = ?)",
                arguments: [account]) ?? false
            guard exists else {
                throw DatabaseError(
                    resultCode: .SQLITE_ERROR,
                    message: "advanceCursor: no accounts row for '\(account)' — cursor not advanced")
            }
        }
    }

    /// Applies one page of history changes and advances the cursor to it —
    /// a thin composition of `applyHistoryChanges` + `advanceCursor` for
    /// callers that don't paginate (`SyncEngine.ensureCursor`, the
    /// 404-expiry re-list). Multi-page pollers must call the two pieces
    /// separately instead — see `applyHistoryChanges`'s doc comment.
    public func applyHistory(
        _ changes: [HistoryChange], newCursor: Int64, account: String
    ) async throws -> [String] {
        let unknownIDs = try await applyHistoryChanges(changes, account: account)
        try await advanceCursor(to: newCursor, account: account)
        return unknownIDs
    }

    /// Removes a message that provably no longer exists server-side (a
    /// hydration `getMessage` 404 — see `SyncEngine.hydrateBodies`). Mirrors
    /// the `.deleted` branch of `applyHistory`: tombstone then delete, in ONE
    /// transaction, so the row leaves `messageIDsNeedingBodies`'s work-list
    /// instead of 404ing forever. `message_bodies`/`message_labels` rows
    /// cascade via their foreign keys; `fts_messages`/`message_seq` do not
    /// (a plain FTS5 table has no FK/cascade machinery), so `FTSIndex.deleteIndex`
    /// removes those explicitly. Also mirrors `.deleted`'s rollup
    /// handling: thread_id captured before the delete, then the ONE
    /// affected thread's rollup row is fully rebuilt (or dropped) via
    /// `ThreadRollup.recomputeThreadRollup` — a deletion can't be folded
    /// into `maintainRollup`'s incremental upsert. Also mirrors `.deleted`'s
    /// AI-artifact purge (Task 8): `AIArtifacts.purge` deletes any cached
    /// artifact `id` fed, in this same transaction — a thread summary has no
    /// FK cascade from one of its source messages (see
    /// `ai_artifact_sources`'s schema comment in `Migrations.swift`), so
    /// this is what keeps the cache from serving stale content built from a
    /// message that no longer exists.
    public func deleteVanishedMessage(id: String, account: String) async throws {
        try await writer.write { db in
            let threadID = try String.fetchOne(
                db,
                sql: "SELECT thread_id FROM messages WHERE account_email = ? AND id = ?",
                arguments: [account, id])
            try db.execute(
                sql: "INSERT OR IGNORE INTO tombstones (account_email, message_id) VALUES (?, ?)",
                arguments: [account, id])
            try db.execute(
                sql: "DELETE FROM messages WHERE account_email = ? AND id = ?",
                arguments: [account, id])
            try FTSIndex.deleteIndex(messageID: id, account: account, db: db)
            try AIArtifacts.purge(sourceMessageID: id, account: account, db: db)
            if let threadID {
                try ThreadRollup.recomputeThreadRollup(threadID: threadID, account: account, db: db)
            }
        }
    }

    /// Caches Gmail's label id→name mapping for display.
    public func upsertLabels(
        _ labels: [(id: String, name: String)], account: String
    ) async throws {
        try await writer.write { db in
            for label in labels {
                try db.execute(
                    sql: """
                        INSERT INTO labels (account_email, id, name) VALUES (?, ?, ?)
                        ON CONFLICT(account_email, id) DO UPDATE SET name = excluded.name
                        """,
                    arguments: [account, label.id, label.name])
            }
        }
    }

    // MARK: - Transaction bodies (synchronous, called inside writer.write)

    /// Returns `wasInsert` alongside the outcome so callers (`applySnapshot`,
    /// `applySnapshots`, `applyHistoryChanges`'s `.added` branch) know
    /// whether this was a same-message UPDATE — needed to trigger the
    /// targeted `ThreadRollup.recomputeThreadFlags` that `maintainRollup`'s
    /// insert-only OR-merge can't do (see `ThreadRollup.maintainRollup`).
    /// `wasInsert` is meaningless (`false`) for `.tombstoned`/`.stale`,
    /// which never reach the upsert.
    ///
    /// `splitRules` lets a batch caller (`applySnapshots`,
    /// `applyHistoryChanges`) load the account's `split_rules` ONCE and
    /// pass the same array to every message in the batch, instead of each
    /// message re-querying it — see `ThreadRollup.maintainRollup`'s doc
    /// comment. `nil` (the default, used by the single-message
    /// `applySnapshot`) fetches them once here instead — still exactly one
    /// small indexed read for that one message, not a re-query "per
    /// message in a loop".
    static func applySnapshotInTransaction(
        _ snapshot: MessageSnapshot, account: String, db: Database,
        splitRules: [SplitRule]? = nil
    ) throws -> (outcome: SnapshotOutcome, wasInsert: Bool) {
        let tombstoned = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM tombstones WHERE account_email = ? AND message_id = ?)",
            arguments: [account, snapshot.id]) ?? false
        if tombstoned { return (.tombstoned, false) }

        if let stored = try Int64.fetchOne(
            db,
            sql: "SELECT history_id FROM messages WHERE account_email = ? AND id = ?",
            arguments: [account, snapshot.id]), stored > snapshot.historyID {
            return (.stale, false)
        }

        // Determined BEFORE the upsert below (which would make every row
        // "exist") — gates `ThreadRollup.maintainRollup`'s message_count
        // increment: a re-applied update of a message we already have must
        // not double-count.
        let wasInsert = try !(Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE account_email = ? AND id = ?)",
            arguments: [account, snapshot.id]) ?? false)

        try db.execute(
            sql: """
                INSERT INTO threads (account_email, id, last_message_at) VALUES (?, ?, ?)
                ON CONFLICT(account_email, id)
                DO UPDATE SET last_message_at = MAX(
                    IFNULL(last_message_at, excluded.last_message_at), excluded.last_message_at)
                """,
            arguments: [account, snapshot.threadID, snapshot.internalDate])
        try db.execute(
            sql: """
                INSERT INTO messages (account_email, id, thread_id, history_id, internal_date,
                                      from_line, to_line, subject, snippet)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_email, id) DO UPDATE SET
                    history_id = excluded.history_id,
                    thread_id = excluded.thread_id,
                    internal_date = excluded.internal_date,
                    from_line = excluded.from_line,
                    to_line = excluded.to_line,
                    subject = excluded.subject,
                    snippet = excluded.snippet
                """,
            arguments: [
                account, snapshot.id, snapshot.threadID, snapshot.historyID,
                snapshot.internalDate, snapshot.fromLine, snapshot.toLine,
                snapshot.subject, snapshot.snippet,
            ])
        try replaceLabels(snapshot.labelIDs, messageID: snapshot.id, account: account, db: db)
        let rules = try splitRules ?? SplitInbox.fetchRules(account: account, db: db)
        try ThreadRollup.maintainRollup(
            afterApplying: snapshot, wasInsert: wasInsert, account: account, db: db, rules: rules)
        try FTSIndex.stubIndex(snapshot, account: account, db: db)
        return (.applied, wasInsert)
    }

    static func replaceLabels(
        _ labelIDs: [String], messageID: String, account: String, db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM message_labels WHERE account_email = ? AND message_id = ?",
            arguments: [account, messageID])
        for labelID in labelIDs {
            try db.execute(
                sql: "INSERT OR IGNORE INTO message_labels (account_email, message_id, label_id) VALUES (?, ?, ?)",
                arguments: [account, messageID, labelID])
        }
    }
}
