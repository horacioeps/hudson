import GRDB
import Testing
@testable import Store

@Test func batchAppliesAllInOneTransactionAndCountsApplied() async throws {
    let db = try HudsonDatabase.inMemory()
    let snaps = (1...3).map { i in
        MessageSnapshot(id: "m\(i)", threadID: "t", historyID: Int64(i), internalDate: Int64(i),
            fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]) }
    let applied = try await db.applySnapshots(snaps, account: "x")
    #expect(applied == 3)
    #expect(try await db.recentMessages(account: "x", limit: 10).count == 3)
}

@Test func oneStaleMessageInBatchDoesNotBlockOthers() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(MessageSnapshot(id: "m2", threadID: "t", historyID: 99,
        internalDate: 2, fromLine: "f", toLine: "t", subject: "s2", snippet: "sn", labelIDs: ["INBOX"]),
        account: "x")
    // Batch includes a STALE m2 (older historyID) plus fresh m1, m3.
    let snaps = [
        MessageSnapshot(id: "m1", threadID: "t", historyID: 1, internalDate: 1, fromLine: "f", toLine: "t", subject: "s1", snippet: "sn", labelIDs: ["INBOX"]),
        MessageSnapshot(id: "m2", threadID: "t", historyID: 5, internalDate: 2, fromLine: "f", toLine: "t", subject: "OLD", snippet: "sn", labelIDs: ["INBOX"]),
        MessageSnapshot(id: "m3", threadID: "t", historyID: 3, internalDate: 3, fromLine: "f", toLine: "t", subject: "s3", snippet: "sn", labelIDs: ["INBOX"]),
    ]
    let applied = try await db.applySnapshots(snaps, account: "x")
    #expect(applied == 2)  // m1, m3 applied; m2 stale
    let m2 = try #require(try await db.message(id: "m2", account: "x")).row
    #expect(m2.subject == "s2")  // stale write rejected, newer kept
}
