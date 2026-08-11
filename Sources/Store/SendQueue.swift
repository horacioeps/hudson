import Foundation
import GRDB

/// State of one outbound message in `send_jobs`' durability state machine
/// (spec §7.3). `pending` moves to `held` only while an undo-send hold is
/// still being offered to the user; either sits in `claimSendable`'s
/// worklist until `hold_until` passes. `in_flight` is committed BEFORE the
/// network call — the ordering that makes the restart dedup probe provable
/// under a kill between "sent on the wire" and "recorded sent". `sent` and
/// `failed` are both terminal.
public enum SendJobState: String, Sendable, Equatable {
    case pending, held, inFlight = "in_flight", sent, failed
}

/// One durable outbound-send job — the send side's twin of
/// `PendingMutation` (`MutationQueue.swift`). `rfc822MessageID` is the
/// UUID `Message-ID` SendService assigns at enqueue (Outbox target, later
/// M5 tasks) and is exactly what the restart dedup probe searches Gmail
/// for; the UNIQUE `(account, rfc822MessageID)` index makes a duplicate
/// enqueue of the same message impossible at the database layer, not just
/// by caller convention.
public struct SendJob: Sendable, Equatable {
    public let id: Int64
    public let account: String
    public let rfc822MessageID: String
    public let threadID: String?
    public let rawMIME: Data
    public let state: SendJobState
    public let holdUntil: Int64       // ms since epoch; undo-send window end
    public let enqueuedAt: Int64      // ms since epoch
    public let sentMessageID: String?
}

extension HudsonDatabase {
    /// Persists a new send job as `pending`. The MIME bytes and
    /// Message-ID are already finalized by the caller (Outbox's
    /// MimeBuilder/SendService build+validate them before this is ever
    /// called) — this layer only stores and drains them, mirroring how
    /// `enqueueMutation` never itself decides label deltas. `holdUntil`
    /// (ms since epoch) is the undo-send window's end; `claimSendable`
    /// won't surface the job to the flusher until then.
    public func enqueueSend(
        account: String, rfc822MessageID: String, threadID: String?,
        rawMIME: Data, holdUntil: Int64, now: Int64
    ) async throws -> Int64 {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO send_jobs
                        (account_email, rfc822_message_id, thread_id, raw_mime, state, hold_until, enqueued_at)
                    VALUES (?, ?, ?, ?, 'pending', ?, ?)
                    """,
                arguments: [account, rfc822MessageID, threadID, rawMIME, holdUntil, now])
            return db.lastInsertedRowID
        }
    }

    /// Jobs ready for the flusher to send: still `pending`/`held` (never
    /// touched the network) and past their undo-send hold, oldest first —
    /// mirrors `claimPendingBatch`'s FIFO drain order.
    public func claimSendable(account: String, now: Int64) async throws -> [SendJob] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM send_jobs
                    WHERE account_email = ? AND state IN ('pending', 'held') AND hold_until <= ?
                    ORDER BY id
                    """,
                arguments: [account, now]
            ).map(Self.sendJob(from:))
        }
    }

    /// The dedup protocol's load-bearing write (§7.3): callers MUST await
    /// this commit before ever calling `sendRawMessage`. If the process
    /// dies between this commit and the network call returning, the job is
    /// left `in_flight` with unknown outcome — exactly the state
    /// `inFlightSendJobs` plus the restart probe exist to resolve, instead
    /// of blindly resending into a possible duplicate.
    public func markSendInFlight(id: Int64, account: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE send_jobs SET state = 'in_flight'
                    WHERE id = ? AND account_email = ? AND state IN ('pending', 'held')
                    """,
                arguments: [id, account])
        }
    }

    /// Terminal success. `sentMessageID` is Gmail's own message id (from
    /// the `messages.send` response) — distinct from `rfc822_message_id`,
    /// the RFC `Message-ID` header used for dedup and threading.
    public func markSent(id: Int64, account: String, sentMessageID: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE send_jobs SET state = 'sent', sent_message_id = ?
                    WHERE id = ? AND account_email = ?
                    """,
                arguments: [sentMessageID, id, account])
        }
    }

    /// Terminal failure. Callers must only reach this on a DEFINITIVE
    /// non-delivery signal (§7.3) — an ambiguous restart-probe miss must
    /// leave the job `in_flight` for re-probing instead, never call this.
    public func markSendFailed(id: Int64, account: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE send_jobs SET state = 'failed' WHERE id = ? AND account_email = ?",
                arguments: [id, account])
        }
    }

    /// Jobs of unknown outcome after a crash or restart — the restart
    /// dedup probe's worklist (§7.3). Each is re-checked against Gmail
    /// (`rfc822msgid` search) before the caller decides sent / resend /
    /// wait-and-reprobe.
    public func inFlightSendJobs(account: String) async throws -> [SendJob] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM send_jobs WHERE account_email = ? AND state = 'in_flight' ORDER BY id",
                arguments: [account]
            ).map(Self.sendJob(from:))
        }
    }

    /// Undo-send: deletes the job outright, but ONLY while it is still
    /// `pending`/`held` AND within its hold window (`hold_until > now`).
    /// Once a job has gone `in_flight` — or its hold has simply elapsed,
    /// even if the flusher hasn't claimed it yet — the send may already be
    /// irrevocably in motion, so cancellation is refused (`false`) rather
    /// than deleting a row a network call might still reference.
    @discardableResult
    public func cancelSend(id: Int64, account: String, now: Int64) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM send_jobs
                    WHERE id = ? AND account_email = ? AND state IN ('pending', 'held') AND hold_until > ?
                    """,
                arguments: [id, account, now])
            return db.changesCount > 0
        }
    }

    private static func sendJob(from row: Row) -> SendJob {
        SendJob(
            id: row["id"], account: row["account_email"],
            rfc822MessageID: row["rfc822_message_id"], threadID: row["thread_id"],
            rawMIME: row["raw_mime"], state: SendJobState(rawValue: row["state"]) ?? .failed,
            holdUntil: row["hold_until"], enqueuedAt: row["enqueued_at"],
            sentMessageID: row["sent_message_id"])
    }
}
