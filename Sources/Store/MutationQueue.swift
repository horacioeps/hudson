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
    /// live delta cancels it (net no-op); same op is idempotent.
    public func enqueueMutation(
        messageID: String, labelID: String, op: LabelOp, account: String, now: Int64
    ) async throws {
        try await writer.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, op FROM mutation_queue
                    WHERE account_email = ? AND message_id = ? AND label_id = ?
                    """,
                arguments: [account, messageID, labelID])
            if let existing {
                let existingOp: String = existing["op"]
                if existingOp == op.rawValue { return }            // same op: idempotent
                let id: Int64 = existing["id"]
                try db.execute(
                    sql: "DELETE FROM mutation_queue WHERE id = ?", arguments: [id])  // opposite: cancel
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO mutation_queue
                        (account_email, message_id, label_id, op, enqueued_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [account, messageID, labelID, op.rawValue, now])
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
}
