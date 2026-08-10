import Foundation
import GRDB

/// Which way a pending label delta points.
public enum LabelOp: String, Sendable, Equatable { case add, remove }

/// One live, not-yet-confirmed local label change.
public struct PendingMutation: Sendable, Equatable {
    public let id: Int64
    public let messageID: String
    public let labelID: String
    public let op: LabelOp
    public let state: String
    public let expectedHistoryID: Int64?
}

extension HudsonDatabase {
    /// Enqueues a label delta as PENDING SERVER TRUTH-PRESERVING intent
    /// (spec §5): canonical tables are never written here. Opposite op to a
    /// live `pending` delta cancels it (net no-op, nothing was ever sent);
    /// same op is idempotent. An opposite op against an `in_flight` delta
    /// (already sent to Gmail, echo not yet retired — Task 9) is NOT a
    /// cancel: the row is overlaid forward to the new op and reset to
    /// `pending` instead of deleted. Deleting it here would silently drop
    /// the new intent (there is nothing left in the queue to send it), since
    /// the already-in-flight send can't be recalled — a deterministic lost
    /// update caught in the M3 final-review pass. Overlaying keeps the
    /// unique index satisfied (same row, not a second insert) and the
    /// effective-read overlay correct throughout: `messageRow` treats every
    /// row here as live regardless of state.
    ///
    /// **M3↔M4 seam (Task 5):** every branch that actually changes the
    /// queue also calls `ThreadRollup.recomputeThreadFlags` for
    /// `messageID`'s thread, in the SAME transaction — `thread_rollup`'s
    /// `in_inbox`/`unread` are overlay-aware (Task 2), so this is what
    /// makes an optimistic archive/read/star drop or surface a thread in
    /// `inboxThreads` (Task 5) instantly, before the change ever reaches
    /// Gmail. The idempotent same-op return is the one exception: nothing
    /// changed, so there's nothing to recompute.
    public func enqueueMutation(
        messageID: String, labelID: String, op: LabelOp, account: String, now: Int64
    ) async throws {
        try await writer.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, op, state FROM mutation_queue
                    WHERE account_email = ? AND message_id = ? AND label_id = ?
                    """,
                arguments: [account, messageID, labelID])
            if let existing {
                let existingOp: String = existing["op"]
                if existingOp == op.rawValue { return }            // same op: idempotent
                let id: Int64 = existing["id"]
                let existingState: String = existing["state"]
                if existingState == "in_flight" {
                    // Sent, not yet retired — can't be recalled. Flip it to
                    // the new op and re-arm it as pending; the flusher sends
                    // the inverse normally once it's claimed.
                    try db.execute(
                        sql: """
                            UPDATE mutation_queue
                            SET op = ?, state = 'pending', expected_history_id = NULL, enqueued_at = ?
                            WHERE id = ?
                            """,
                        arguments: [op.rawValue, now, id])
                    try Self.recomputeThreadsForMessages([messageID], account: account, db: db)
                    return
                }
                try db.execute(
                    sql: "DELETE FROM mutation_queue WHERE id = ?", arguments: [id])  // opposite, still pending: cancel
                try Self.recomputeThreadsForMessages([messageID], account: account, db: db)
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO mutation_queue
                        (account_email, message_id, label_id, op, enqueued_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [account, messageID, labelID, op.rawValue, now])
            try Self.recomputeThreadsForMessages([messageID], account: account, db: db)
        }
    }

    /// All live deltas for an account, oldest first (drain order).
    public func pendingMutations(account: String) async throws -> [PendingMutation] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM mutation_queue WHERE account_email = ? ORDER BY id",
                arguments: [account]
            ).map(Self.pendingMutation(from:))
        }
    }

    static func pendingMutation(from row: Row) -> PendingMutation {
        PendingMutation(
            id: row["id"], messageID: row["message_id"], labelID: row["label_id"],
            op: LabelOp(rawValue: row["op"]) ?? .add, state: row["state"],
            expectedHistoryID: row["expected_history_id"])
    }

    /// Oldest `pending` rows for the flusher to send, FIFO.
    public func claimPendingBatch(account: String, limit: Int) async throws -> [PendingMutation] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM mutation_queue
                    WHERE account_email = ? AND state = 'pending' ORDER BY id LIMIT ?
                    """,
                arguments: [account, limit]
            ).map(Self.pendingMutation(from:))
        }
    }

    /// Marks sent mutations in_flight and records the historyId the modify
    /// returned as the retirement gate (spec §5 / architecture M3).
    public func markInFlight(
        mutationIDs: [Int64], expectedHistoryID: Int64, account: String
    ) async throws {
        guard !mutationIDs.isEmpty else { return }
        try await writer.write { db in
            let placeholders = databaseQuestionMarks(count: mutationIDs.count)
            var args: StatementArguments = [expectedHistoryID, account]
            args += StatementArguments(mutationIDs)
            try db.execute(
                sql: """
                    UPDATE mutation_queue SET state = 'in_flight', expected_history_id = ?
                    WHERE account_email = ? AND id IN (\(placeholders))
                    """,
                arguments: args)
        }
    }

    /// Retires in_flight deltas whose echo has landed (account cursor has
    /// reached the modify's historyId). Retiring earlier — on 2xx — would drop
    /// the overlay before the canonical write echoes back, flickering the row.
    ///
    /// **M3↔M4 seam (Task 5):** the affected messages' `message_id`s are
    /// captured BEFORE the delete (the rows are gone afterward), then each
    /// distinct touched thread's rollup flags are recomputed once — so
    /// `thread_rollup` stays in lockstep with `mutation_queue` the instant
    /// the overlay changes under it, rather than relying on some other,
    /// unrelated event to eventually touch that thread.
    public func retireConfirmedMutations(account: String) async throws -> Int {
        try await writer.write { db in
            let cursor = try Int64.fetchOne(
                db, sql: "SELECT history_cursor FROM accounts WHERE email = ?",
                arguments: [account])
            guard let cursor else { return 0 }
            let affectedMessageIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT message_id FROM mutation_queue
                    WHERE account_email = ? AND state = 'in_flight'
                      AND expected_history_id IS NOT NULL AND expected_history_id <= ?
                    """,
                arguments: [account, cursor])
            try db.execute(
                sql: """
                    DELETE FROM mutation_queue
                    WHERE account_email = ? AND state = 'in_flight'
                      AND expected_history_id IS NOT NULL AND expected_history_id <= ?
                    """,
                arguments: [account, cursor])
            let retired = db.changesCount
            try Self.recomputeThreadsForMessages(affectedMessageIDs, account: account, db: db)
            return retired
        }
    }

    /// Terminal-failure removal — the flusher re-derives truth afterwards.
    /// **M3↔M4 seam (Task 5):** the message id is read off the row BEFORE
    /// deleting it, then its thread's rollup flags are recomputed — a
    /// dropped optimistic archive/read must revert the thread back to
    /// canonical truth in `inboxThreads` immediately, not just in the
    /// per-message overlay read.
    public func dropMutation(id: Int64, account: String) async throws {
        try await writer.write { db in
            let messageID = try String.fetchOne(
                db, sql: "SELECT message_id FROM mutation_queue WHERE id = ? AND account_email = ?",
                arguments: [id, account])
            try db.execute(
                sql: "DELETE FROM mutation_queue WHERE id = ? AND account_email = ?",
                arguments: [id, account])
            if let messageID {
                try Self.recomputeThreadsForMessages([messageID], account: account, db: db)
            }
        }
    }

    /// Recomputes `thread_rollup`'s overlay-aware `unread`/`in_inbox` flags
    /// for every DISTINCT thread among `messageIDs` — deduped so a batch
    /// touching several messages in the same thread (`retireConfirmedMutations`)
    /// costs one recompute per thread, not one per message. A message id
    /// with no known thread (not locally hydrated yet) is silently skipped.
    private static func recomputeThreadsForMessages(
        _ messageIDs: [String], account: String, db: Database
    ) throws {
        guard !messageIDs.isEmpty else { return }
        var threadIDs = Set<String>()
        for messageID in messageIDs {
            if let threadID = try String.fetchOne(
                db, sql: "SELECT thread_id FROM messages WHERE account_email = ? AND id = ?",
                arguments: [account, messageID]
            ) {
                threadIDs.insert(threadID)
            }
        }
        for threadID in threadIDs {
            try ThreadRollup.recomputeThreadFlags(threadID: threadID, account: account, db: db)
        }
    }
}

/// `?, ?, …` of length `count` for an IN clause.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
