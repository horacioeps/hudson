import Foundation
import GRDB

extension HudsonDatabase {
    /// Stores a sanitized body, flags the message hydrated, and reindexes the
    /// message's FTS row WITH the new body — all in one transaction. Also the
    /// path a `Sanitizer.version` bump re-derives through: `messageIDsNeedingBodies`
    /// picks up outdated-version rows, hydration re-sanitizes, and this call
    /// both overwrites `message_bodies` and refreshes `fts_messages` to match.
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
            try FTSIndex.reindexBody(
                messageID: messageID, account: account, plainText: body.plainText, db: db)
        }
    }

    /// The hydration work-list: newest un-hydrated messages, or those with
    /// outdated sanitizer versions, within the window. Bumping Sanitizer.version
    /// automatically re-derives all existing bodies.
    public func messageIDsNeedingBodies(
        account: String, since: Int64, limit: Int
    ) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT m.id FROM messages m
                    WHERE m.account_email = ? AND m.internal_date >= ?
                      AND (m.has_body = 0 OR EXISTS (
                        SELECT 1 FROM message_bodies b
                        WHERE b.account_email = m.account_email
                          AND b.message_id = m.id
                          AND b.sanitizer_version < ?
                      ))
                    ORDER BY m.internal_date DESC LIMIT ?
                    """,
                arguments: [account, since, Sanitizer.version, limit])
        }
    }
}
