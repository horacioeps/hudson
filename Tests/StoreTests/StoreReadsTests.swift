import GRDB
import Testing
@testable import Store

@Test func messageReturnsRowWithNilBodyBeforeHydration() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 5, internalDate: 1_000,
        fromLine: "a@example.com", toLine: "b@example.com",
        subject: "s", snippet: "sn", labelIDs: ["INBOX"])
    _ = try await database.applySnapshot(snapshot, account: "x")

    let result = try #require(try await database.message(id: "m1", account: "x"))
    #expect(result.row.id == "m1")
    #expect(result.row.subject == "s")
    #expect(result.plainText == nil)   // no body hydrated yet
}

@Test func messageReturnsNilForMissingId() async throws {
    let database = try HudsonDatabase.inMemory()
    let result = try await database.message(id: "ghost", account: "x")
    #expect(result == nil)
}

@Test func upsertLabelsInsertsThenUpdatesName() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertLabels([(id: "l1", name: "Inbox")], account: "x")
    try await database.upsertLabels([(id: "l1", name: "Primary")], account: "x")

    let name = try await database.writer.read { db in
        try String.fetchOne(
            db, sql: "SELECT name FROM labels WHERE account_email = ? AND id = ?",
            arguments: ["x", "l1"])
    }
    #expect(name == "Primary")
}
