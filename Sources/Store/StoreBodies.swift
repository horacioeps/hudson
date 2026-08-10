import Foundation
import GRDB

/// One attachment's metadata, as recorded in the `attachments` table (Task
/// 1's schema). Store-side type — `SyncEngine` maps GmailKit's
/// `GmailMessage.attachments()` tuples into this so Store keeps importing
/// neither GmailKit nor networking.
public struct AttachmentMeta: Sendable, Equatable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let size: Int

    /// Initializes one attachment's metadata.
    public init(id: String, filename: String, mimeType: String, size: Int) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

extension HudsonDatabase {
    /// Stores a sanitized body, flags the message hydrated, upserts its
    /// attachment metadata, and reindexes the message's FTS row WITH the new
    /// body — all in one transaction. Also the path a `Sanitizer.version`
    /// bump re-derives through: `messageIDsNeedingBodies` picks up
    /// outdated-version rows, hydration re-sanitizes, and this call both
    /// overwrites `message_bodies` and refreshes `fts_messages` to match.
    ///
    /// `has_attachment` is set from `attachments` here — but `attachments`
    /// defaults to empty, so this is EVENTUALLY consistent: the metadata
    /// backfill path (`SnapshotMapping`, `format: "metadata"`/`"minimal"`
    /// gets) never calls `saveBody` and never sees a payload part tree, so a
    /// message only gains `has_attachment = 1` once its `format: "full"`
    /// body hydration runs. Until then it reads `has_attachment = 0` even if
    /// the real message has an attachment. `ThreadRollup.maintainHasAttachment`
    /// (Task 5) mirrors the same flag onto `thread_rollup` in the same
    /// transaction, so `inboxThreads` picks it up with zero join.
    public func saveBody(
        messageID: String, account: String, body: SanitizedBody,
        attachments: [AttachmentMeta] = []
    ) async throws {
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
            for attachment in attachments {
                try db.execute(
                    sql: """
                        INSERT INTO attachments
                            (account_email, message_id, attachment_id, filename, mime_type, size)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(account_email, message_id, attachment_id) DO UPDATE SET
                            filename = excluded.filename, mime_type = excluded.mime_type,
                            size = excluded.size
                        """,
                    arguments: [
                        account, messageID, attachment.id, attachment.filename,
                        attachment.mimeType, attachment.size,
                    ])
            }
            try db.execute(
                sql: "UPDATE messages SET has_attachment = ? WHERE account_email = ? AND id = ?",
                arguments: [!attachments.isEmpty, account, messageID])
            // Mirrors `messages.has_attachment` onto `thread_rollup` (Task
            // 5, M4's zero-join inbox read) — a no-op unless `messageID` is
            // still its thread's current newest message.
            try ThreadRollup.maintainHasAttachment(
                messageID: messageID, hasAttachment: !attachments.isEmpty, account: account, db: db)
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
