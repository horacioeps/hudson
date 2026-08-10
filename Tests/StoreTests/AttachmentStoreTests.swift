import Foundation
import GRDB
import Testing
@testable import Store

private func snap(_ id: String, thread: String = "t1") -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: 1, internalDate: 1,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: [])
}

private func body(_ plainText: String = "hello") -> SanitizedBody {
    Sanitizer.sanitize(html: nil, plainText: plainText)
}

private func hasAttachmentFlag(_ db: HudsonDatabase, id: String, account: String = "x") async throws -> Bool {
    try await db.writer.read { conn in
        try Bool.fetchOne(
            conn, sql: "SELECT has_attachment FROM messages WHERE account_email = ? AND id = ?",
            arguments: [account, id]) ?? false
    }
}

/// A stored `attachments` row's plain-value fields — never leaks a GRDB
/// `Row` across the `async` read boundary (matches the codebase convention;
/// `Row` isn't extracted from inside a `writer.read` closure elsewhere).
private struct StoredAttachment: Equatable {
    let attachmentID: String
    let filename: String
    let mimeType: String
    let size: Int
}

private func attachmentRows(
    _ db: HudsonDatabase, messageID: String, account: String = "x"
) async throws -> [StoredAttachment] {
    try await db.writer.read { conn in
        try Row.fetchAll(
            conn,
            sql: """
                SELECT * FROM attachments WHERE account_email = ? AND message_id = ?
                ORDER BY attachment_id
                """,
            arguments: [account, messageID]
        ).map {
            StoredAttachment(
                attachmentID: $0["attachment_id"], filename: $0["filename"],
                mimeType: $0["mime_type"], size: $0["size"])
        }
    }
}

// MARK: - RED: saveBody with attachments sets has_attachment + inserts rows

@Test func saveBodyWithAttachmentsSetsHasAttachmentAndInsertsRows() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: body(),
        attachments: [
            AttachmentMeta(id: "A1", filename: "report.pdf", mimeType: "application/pdf", size: 5000)
        ])
    #expect(try await hasAttachmentFlag(db, id: "m1"))
    let rows = try await attachmentRows(db, messageID: "m1")
    #expect(rows.count == 1)
    #expect(rows[0].attachmentID == "A1")
    #expect(rows[0].filename == "report.pdf")
    #expect(rows[0].mimeType == "application/pdf")
    #expect(rows[0].size == 5000)
}

@Test func saveBodyWithoutAttachmentsLeavesHasAttachmentFalse() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.saveBody(messageID: "m1", account: "x", body: body())
    #expect(try await hasAttachmentFlag(db, id: "m1") == false)
    #expect(try await attachmentRows(db, messageID: "m1").isEmpty)
}

@Test func saveBodyRecordsMultipleAttachments() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: body(),
        attachments: [
            AttachmentMeta(id: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 100),
            AttachmentMeta(id: "B1", filename: "b.jpg", mimeType: "image/jpeg", size: 200),
        ])
    let rows = try await attachmentRows(db, messageID: "m1")
    #expect(rows.count == 2)
    #expect(try await hasAttachmentFlag(db, id: "m1"))
}

// MARK: - RED: saveBody upserts attachment rows rather than duplicating

@Test func saveBodyUpsertsAttachmentRowsIdempotently() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    let attachments = [AttachmentMeta(id: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 100)]
    try await db.saveBody(messageID: "m1", account: "x", body: body(), attachments: attachments)
    try await db.saveBody(messageID: "m1", account: "x", body: body(), attachments: attachments)
    let rows = try await attachmentRows(db, messageID: "m1")
    #expect(rows.count == 1)  // a re-hydration doesn't duplicate the row
}

@Test func saveBodyUpdatesAttachmentMetadataOnReupsert() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: body(),
        attachments: [AttachmentMeta(id: "A1", filename: "old.pdf", mimeType: "application/pdf", size: 100)])
    try await db.saveBody(
        messageID: "m1", account: "x", body: body(),
        attachments: [AttachmentMeta(id: "A1", filename: "new.pdf", mimeType: "application/pdf", size: 200)])
    let rows = try await attachmentRows(db, messageID: "m1")
    #expect(rows.count == 1)
    #expect(rows[0].filename == "new.pdf")
    #expect(rows[0].size == 200)
}

// MARK: - RED: attachments cascade-delete with their message (Task 1's FK)

@Test func attachmentRowsCascadeDeleteWithMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: body(),
        attachments: [AttachmentMeta(id: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 100)])
    try await db.deleteVanishedMessage(id: "m1", account: "x")
    let rows = try await attachmentRows(db, messageID: "m1")
    #expect(rows.isEmpty)
}

// MARK: - RED: a metadata-only re-apply must not clear an already-set has_attachment

@Test func metadataReapplyPreservesHasAttachmentFlag() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: body(),
        attachments: [AttachmentMeta(id: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 100)])
    #expect(try await hasAttachmentFlag(db, id: "m1"))
    // A metadata-only re-apply (e.g. the cursor-expiry re-list path) never
    // carries an attachment field (spec: `has_attachment` is eventually
    // consistent, only `format:"full"` hydration observes it) — it must not
    // reset the flag back to false.
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    #expect(try await hasAttachmentFlag(db, id: "m1"))
}
