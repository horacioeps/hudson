import Foundation
import GRDB

/// One row of the message list — what the CLI (and later the UI) renders.
public struct MessageRow: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let historyID: Int64
    public let internalDate: Int64
    public let fromLine: String
    public let toLine: String
    public let subject: String
    public let snippet: String
    public let hasBody: Bool
    public let labelIDs: [String]
}

extension HudsonDatabase {
    /// Newest-first message list. Reads SQLite only — never the network (§4 invariant 3).
    public func recentMessages(account: String, limit: Int) async throws -> [MessageRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages WHERE account_email = ?
                    ORDER BY internal_date DESC, id DESC LIMIT ?
                    """,
                arguments: [account, limit])
            return try rows.map { try Self.messageRow(from: $0, account: account, db: db) }
        }
    }

    /// One message plus its sanitized plain text (nil until hydrated).
    public func message(
        id: String, account: String
    ) async throws -> (row: MessageRow, plainText: String?)? {
        try await writer.read { db in
            guard let raw = try Row.fetchOne(
                db,
                sql: "SELECT * FROM messages WHERE account_email = ? AND id = ?",
                arguments: [account, id]) else { return nil }
            let row = try Self.messageRow(from: raw, account: account, db: db)
            let text = try String.fetchOne(
                db,
                sql: "SELECT plain_text FROM message_bodies WHERE account_email = ? AND message_id = ?",
                arguments: [account, id])
            return (row, text)
        }
    }

    static func messageRow(from raw: Row, account: String, db: Database) throws -> MessageRow {
        let id: String = raw["id"]
        let labels = try String.fetchAll(
            db,
            sql: "SELECT label_id FROM message_labels WHERE account_email = ? AND message_id = ? ORDER BY label_id",
            arguments: [account, id])
        return MessageRow(
            id: id, threadID: raw["thread_id"], historyID: raw["history_id"],
            internalDate: raw["internal_date"], fromLine: raw["from_line"],
            toLine: raw["to_line"], subject: raw["subject"], snippet: raw["snippet"],
            hasBody: raw["has_body"], labelIDs: labels)
    }
}
