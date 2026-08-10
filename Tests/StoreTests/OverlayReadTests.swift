import Testing
@testable import Store

private func seed(_ db: HudsonDatabase, id: String, labels: [String]) async throws {
    let snap = MessageSnapshot(
        id: id, threadID: "t", historyID: 1, internalDate: 1000,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: labels)
    _ = try await db.applySnapshot(snap, account: "x")
}

@Test func pendingRemoveHidesLabelFromReads() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seed(db, id: "m1", labels: ["INBOX", "UNREAD"])
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(!row.labelIDs.contains("INBOX"))   // effective view: archived
    #expect(row.labelIDs.contains("UNREAD"))
    // Canonical is untouched — server truth preserved.
    let canonical = try await db.writer.read { try String.fetchAll($0,
        sql: "SELECT label_id FROM message_labels WHERE account_email='x' AND message_id='m1' ORDER BY label_id") }
    #expect(canonical == ["INBOX", "UNREAD"])
}

@Test func pendingAddShowsLabelInReads() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seed(db, id: "m1", labels: ["INBOX"])
    try await db.enqueueMutation(messageID: "m1", labelID: "STARRED", op: .add, account: "x", now: 1)
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(row.labelIDs.contains("STARRED"))
}

@Test func oppositeOpCancelsPendingDelta() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seed(db, id: "m1", labels: ["INBOX"])
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .add, account: "x", now: 2)
    // Re-adding what you just archived cancels out — no live delta, no flush needed.
    #expect(try await db.pendingMutations(account: "x").isEmpty)
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(row.labelIDs.contains("INBOX"))
}
