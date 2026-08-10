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

@Test func emptyHistoryStillWritesCursor() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('x','c',0)")
    }
    // An empty change list is how the sync engine records the initial
    // cursor — it must still write, not be treated as a no-op.
    let unknown = try await database.applyHistory([], newCursor: 7, account: "x")
    #expect(unknown.isEmpty)
    let cursor = try await database.writer.read { db in
        try Int64.fetchOne(db, sql: "SELECT history_cursor FROM accounts WHERE email='x'")
    }
    #expect(cursor == 7)
}

@Test func applyHistoryThrowsWhenAccountIsMissing() async throws {
    let database = try HudsonDatabase.inMemory()
    // No accounts row for 'x' — the cursor UPDATE would silently affect zero
    // rows; §4.3 requires that to fail loudly, not report false success.
    await #expect(throws: DatabaseError.self) {
        _ = try await database.applyHistory([], newCursor: 1, account: "x")
    }
}

@Test func duplicateUnknownLabelEventsYieldOneEntry() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('x','c',0)")
    }
    let unknown = try await database.applyHistory([
        HistoryChange(kind: .labels(id: "ghost", historyID: 1, labelIDs: ["INBOX"])),
        HistoryChange(kind: .labels(id: "ghost", historyID: 2, labelIDs: ["INBOX"])),
    ], newCursor: 2, account: "x")
    #expect(unknown == ["ghost"])
}

@Test func tombstonedLabelEventIsNotSurfacedAsUnknown() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('x','c',0)")
    }
    _ = try await database.applyHistory(
        [HistoryChange(kind: .deleted(id: "m1"))], newCursor: 1, account: "x")
    // A stale label event for a message we already know is deleted must not
    // be surfaced for hydration — it would just 404 on every retry.
    let unknown = try await database.applyHistory(
        [HistoryChange(kind: .labels(id: "m1", historyID: 2, labelIDs: ["INBOX"]))],
        newCursor: 2, account: "x")
    #expect(unknown.isEmpty)
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
