import GRDB
import Testing
@testable import Store

@Test func historyAppliesInOrderAndAdvancesCursor() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: """
            INSERT INTO accounts (email, client_id, consented_at) VALUES ('x', 'c', 0)
            """)
    }
    let added = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 10, internalDate: 1_000,
        fromLine: "a@ex.com", toLine: "b@ex.com", subject: "s", snippet: "sn",
        labelIDs: ["INBOX", "UNREAD"])
    let unknown = try await database.applyHistory([
        HistoryChange(kind: .added(added)),
        HistoryChange(kind: .labels(id: "m1", historyID: 11, labelIDs: ["INBOX"])),  // read
        HistoryChange(kind: .labels(id: "ghost", historyID: 12, labelIDs: ["INBOX"])),
    ], newCursor: 12, account: "x")

    #expect(unknown == ["ghost"])  // unknown id surfaced for hydration, not applied blind
    let row = try #require(try await database.recentMessages(account: "x", limit: 1).first)
    #expect(row.labelIDs == ["INBOX"])   // UNREAD removed by the later event
    #expect(row.historyID == 11)
    let cursor = try await database.writer.read { db in
        try Int64.fetchOne(db, sql: "SELECT history_cursor FROM accounts WHERE email='x'")
    }
    #expect(cursor == 12)
}

@Test func deletionTombstonesAndRemoves() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('x','c',0)")
    }
    let added = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 10, internalDate: 1_000,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"])
    _ = try await database.applyHistory(
        [HistoryChange(kind: .added(added))], newCursor: 10, account: "x")
    _ = try await database.applyHistory(
        [HistoryChange(kind: .deleted(id: "m1"))], newCursor: 11, account: "x")
    #expect(try await database.recentMessages(account: "x", limit: 10).isEmpty)
}
