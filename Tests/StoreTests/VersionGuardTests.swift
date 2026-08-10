import GRDB
import Testing
@testable import Store

private func snapshot(
    id: String = "m1", historyID: Int64, labels: [String] = ["INBOX"]
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: "t1", historyID: historyID, internalDate: 1_000,
        fromLine: "a@example.com", toLine: "b@example.com",
        subject: "s", snippet: "sn", labelIDs: labels)
}

@Test func newerSnapshotApplies() async throws {
    let database = try HudsonDatabase.inMemory()
    #expect(try await database.applySnapshot(snapshot(historyID: 5), account: "x") == .applied)
    #expect(try await database.applySnapshot(snapshot(historyID: 9), account: "x") == .applied)
    let rows = try await database.recentMessages(account: "x", limit: 10)
    #expect(rows.first?.historyID == 9)
}

@Test func staleSnapshotIsDiscarded() async throws {
    let database = try HudsonDatabase.inMemory()
    _ = try await database.applySnapshot(snapshot(historyID: 9, labels: ["ARCHIVED"]), account: "x")
    // A late-arriving older snapshot (e.g. slow backfill get racing a newer
    // history event) must NOT clobber the newer label state — spec §4.2.
    #expect(try await database.applySnapshot(snapshot(historyID: 5), account: "x") == .stale)
    let rows = try await database.recentMessages(account: "x", limit: 10)
    #expect(rows.first?.labelIDs == ["ARCHIVED"])
}

@Test func tombstonedIdRejectsSnapshots() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('x','c',0)")
    }
    _ = try await database.applyHistory(
        [HistoryChange(kind: .deleted(id: "m1"))], newCursor: 4, account: "x")
    // A backfill page listing the deleted message arrives late — it must not resurrect.
    #expect(try await database.applySnapshot(snapshot(historyID: 3), account: "x") == .tombstoned)
    #expect(try await database.recentMessages(account: "x", limit: 10).isEmpty)
}

@Test func equalHistoryIDStillApplies() async throws {
    let database = try HudsonDatabase.inMemory()
    #expect(try await database.applySnapshot(snapshot(historyID: 9), account: "x") == .applied)
    // Same historyID again (e.g. a redelivered snapshot) must still apply —
    // the guard is `stored > incoming`, not `>=`. A `>=` → `>` regression on
    // the guard would incorrectly discard this as stale.
    #expect(try await database.applySnapshot(snapshot(historyID: 9), account: "x") == .applied)
}
