import Foundation
import GRDB

extension HudsonDatabase {
    /// Stores a sanitized body and flags the message hydrated — one transaction.
    public func saveBody(messageID: String, account: String, body: SanitizedBody) async throws {
        let cids = String(decoding: try JSONEncoder().encode(body.cidReferences), as: UTF8.self)
        let urls = String(decoding: try JSONEncoder().encode(body.remoteURLs), as: UTF8.self)
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message_bodies
                        (account_email, message_id, raw_html, plain_text,
                         sanitizer_version, cid_references, remote_urls)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_email, message_id) DO UPDATE SET
                        raw_html = excluded.raw_html, plain_text = excluded.plain_text,
                        sanitizer_version = excluded.sanitizer_version,
                        cid_references = excluded.cid_references,
                        remote_urls = excluded.remote_urls
                    """,
                arguments: [
                    account, messageID, body.rawHTML, body.plainText,
                    body.sanitizerVersion, cids, urls,
                ])
            try db.execute(
                sql: "UPDATE messages SET has_body = 1 WHERE account_email = ? AND id = ?",
                arguments: [account, messageID])
        }
    }

    /// The hydration work-list: newest un-hydrated messages within the window.
    public func messageIDsNeedingBodies(
        account: String, since: Int64, limit: Int
    ) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM messages
                    WHERE account_email = ? AND has_body = 0 AND internal_date >= ?
                    ORDER BY internal_date DESC LIMIT ?
                    """,
                arguments: [account, since, limit])
        }
    }
}
