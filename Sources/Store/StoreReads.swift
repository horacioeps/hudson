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
    /// This message's own RFC 5322 `Message-ID`/`References` headers, as
    /// persisted by `applySnapshot` (M5 Task 5) — the raw material
    /// `Outbox.replyMessage` needs to build the threading triple's
    /// `In-Reply-To`/`References` legs off the thread's newest message.
    /// `nil` for messages hydrated before those columns existed, or for a
    /// source fetch that never carried headers (see
    /// `MessageSnapshot.rfc822MessageID`'s doc comment).
    public let rfc822MessageID: String?
    public let referencesHeader: String?
}

/// A message's derived body content for the reading pane, mirroring what
/// `saveBody` persisted to `message_bodies`: the sanitized `plainText`, the
/// raw (sender-authored) `rawHTML` bytes the WKWebView renderer displays, and
/// the sanitizer's inventories of `remoteURLs`/`cidReferences`. `remoteURLs`
/// is what the renderer keeps blocked until the user explicitly opts into
/// loading remote images (Hudson's #1 rule: leak nothing to the network by
/// default).
public struct MessageBody: Sendable, Equatable {
    public let plainText: String?
    public let rawHTML: Data?
    public let remoteURLs: [String]
    public let cidReferences: [String]

    public init(plainText: String?, rawHTML: Data?, remoteURLs: [String], cidReferences: [String]) {
        self.plainText = plainText
        self.rawHTML = rawHTML
        self.remoteURLs = remoteURLs
        self.cidReferences = cidReferences
    }
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

    /// The full stored body for one message, or `nil` when none is hydrated
    /// yet. Unlike `message(id:)` (which returns only the sanitized plain
    /// text), this carries everything the reading pane's HTML renderer needs:
    /// the raw, still-sender-authored HTML bytes, plus the inventories of
    /// remote/cid references the sanitizer catalogued so the renderer can
    /// enforce Hudson's remote-blocking privacy rule. Reads SQLite only —
    /// never the network (§4 invariant 3).
    public func messageBody(id: String, account: String) async throws -> MessageBody? {
        try await writer.read { db in
            guard let raw = try Row.fetchOne(
                db,
                sql: """
                    SELECT plain_text, raw_html, remote_urls, cid_references
                    FROM message_bodies WHERE account_email = ? AND message_id = ?
                    """,
                arguments: [account, id]) else { return nil }
            return MessageBody(
                plainText: raw["plain_text"],
                rawHTML: raw["raw_html"],
                remoteURLs: Self.decodeStringArray(raw["remote_urls"]),
                cidReferences: Self.decodeStringArray(raw["cid_references"]))
        }
    }

    /// Decodes a `[String]` from the JSON text `saveBody` stored it as (a
    /// `JSONEncoder`-encoded `[String]`), so the round-trip is lossless. A
    /// `nil`, empty, or corrupt value yields `[]` rather than throwing —
    /// a malformed inventory must never block reading an otherwise-good body.
    static func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func messageRow(from raw: Row, account: String, db: Database) throws -> MessageRow {
        let id: String = raw["id"]
        // Effective labels = (canonical ∪ pending adds) − pending removes —
        // see `EffectiveLabels.fragment` (Task 7: shared across this and
        // three other call sites, was hand-duplicated before).
        let labels = try String.fetchAll(
            db,
            sql: EffectiveLabels.fragment(account: ":acct", messageID: ":mid") + " ORDER BY label_id",
            arguments: ["acct": account, "mid": id])
        return MessageRow(
            id: id, threadID: raw["thread_id"], historyID: raw["history_id"],
            internalDate: raw["internal_date"], fromLine: raw["from_line"],
            toLine: raw["to_line"], subject: raw["subject"], snippet: raw["snippet"],
            hasBody: raw["has_body"], labelIDs: labels,
            rfc822MessageID: raw["rfc822_message_id"], referencesHeader: raw["references_header"])
    }
}
