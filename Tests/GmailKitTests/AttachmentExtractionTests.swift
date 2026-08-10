import Foundation
import Testing
@testable import GmailKit

/// Decodes an inline JSON literal into a `GmailMessage` — mirrors
/// `ScriptedGmail`'s `testMessage` helpers in SyncEngineTests, but local to
/// this file since `attachments()` only needs the payload/part tree, not the
/// full metadata envelope those helpers build.
private func message(_ json: String) -> GmailMessage {
    try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
}

@Test func extractsSingleAttachmentFromTopLevelPart() {
    let msg = message(
        """
        {"id": "m1", "threadId": "t1", "historyId": "1",
         "payload": {"mimeType": "multipart/mixed", "parts": [
           {"mimeType": "text/plain", "body": {"data": "aGk", "size": 2}},
           {"mimeType": "application/pdf", "filename": "report.pdf",
            "body": {"attachmentId": "ABC123", "size": 5000}}
         ]}}
        """)
    let attachments = msg.attachments()
    #expect(attachments.count == 1)
    #expect(attachments[0].attachmentID == "ABC123")
    #expect(attachments[0].filename == "report.pdf")
    #expect(attachments[0].mimeType == "application/pdf")
    #expect(attachments[0].size == 5000)
}

@Test func returnsEmptyArrayWhenNoAttachmentParts() {
    let msg = message(
        """
        {"id": "m1", "threadId": "t1", "historyId": "1",
         "payload": {"mimeType": "multipart/alternative", "parts": [
           {"mimeType": "text/plain", "body": {"data": "aGk"}},
           {"mimeType": "text/html", "body": {"data": "aGk"}}
         ]}}
        """)
    #expect(msg.attachments().isEmpty)
}

@Test func returnsEmptyArrayWhenPayloadIsNil() {
    let msg = message(#"{"id": "m1", "threadId": "t1", "historyId": "1"}"#)
    #expect(msg.attachments().isEmpty)
}

@Test func walksNestedPartTreeToFindDeeplyNestedAttachment() {
    let msg = message(
        """
        {"id": "m1", "threadId": "t1", "historyId": "1",
         "payload": {"mimeType": "multipart/mixed", "parts": [
           {"mimeType": "multipart/alternative", "parts": [
             {"mimeType": "text/plain", "body": {"data": "aGk"}},
             {"mimeType": "text/html", "body": {"data": "aGk"}}
           ]},
           {"mimeType": "multipart/mixed", "parts": [
             {"mimeType": "image/png", "filename": "diagram.png",
              "body": {"attachmentId": "IMG1", "size": 12000}}
           ]}
         ]}}
        """)
    let attachments = msg.attachments()
    #expect(attachments.count == 1)
    #expect(attachments[0].filename == "diagram.png")
    #expect(attachments[0].attachmentID == "IMG1")
    #expect(attachments[0].mimeType == "image/png")
}

// Gmail inlines small attachments directly via body.data (no attachmentId) —
// those aren't lazily downloadable by id, so they're excluded here.
@Test func ignoresPartsWithFilenameButNoAttachmentID() {
    let msg = message(
        """
        {"id": "m1", "threadId": "t1", "historyId": "1",
         "payload": {"mimeType": "multipart/mixed", "parts": [
           {"mimeType": "text/plain", "body": {"data": "aGk"}},
           {"mimeType": "text/plain", "filename": "small.txt",
            "body": {"data": "c21hbGw", "size": 5}}
         ]}}
        """)
    #expect(msg.attachments().isEmpty)
}

@Test func ignoresPartsWithAttachmentIDButEmptyFilename() {
    let msg = message(
        """
        {"id": "m1", "threadId": "t1", "historyId": "1",
         "payload": {"mimeType": "multipart/mixed", "parts": [
           {"mimeType": "text/plain", "filename": "",
            "body": {"attachmentId": "X1", "size": 10}}
         ]}}
        """)
    #expect(msg.attachments().isEmpty)
}

@Test func collectsMultipleAttachmentsInDepthFirstOrder() {
    let msg = message(
        """
        {"id": "m1", "threadId": "t1", "historyId": "1",
         "payload": {"mimeType": "multipart/mixed", "parts": [
           {"mimeType": "application/pdf", "filename": "a.pdf",
            "body": {"attachmentId": "A1", "size": 100}},
           {"mimeType": "image/jpeg", "filename": "b.jpg",
            "body": {"attachmentId": "B1", "size": 200}}
         ]}}
        """)
    let attachments = msg.attachments()
    #expect(attachments.map(\.filename) == ["a.pdf", "b.jpg"])
    #expect(attachments.map(\.attachmentID) == ["A1", "B1"])
    #expect(attachments.map(\.size) == [100, 200])
}
