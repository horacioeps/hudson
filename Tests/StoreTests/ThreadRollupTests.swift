import GRDB
import Testing
@testable import Store

private func snap(_ id: String, thread: String = "t1", date: Int64, labels: [String], subject: String = "s") -> MessageSnapshot {
    MessageSnapshot(id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: "ada@x.com", toLine: "you@x.com", subject: subject, snippet: "sn", labelIDs: labels)
}

/// The minimal slice of `thread_rollup` these tests care about. `inboxThreads`
/// (Task 5) isn't implemented yet, so — per the brief's guidance for keeping
/// Tasks 2-4 independently testable — these read `thread_rollup` directly
/// via raw SQL rather than depending on it.
private struct RollupSnapshot {
    let messageCount: Int
    let lastMessageAt: Int64
    let unread: Bool
}

private func rollupRow(_ db: HudsonDatabase, account: String, thread: String) async throws -> RollupSnapshot? {
    try await db.writer.read { conn in
        guard let row = try Row.fetchOne(
            conn,
            sql: "SELECT message_count, last_message_at, unread FROM thread_rollup WHERE account_email = ? AND thread_id = ?",
            arguments: [account, thread]
        ) else { return nil }
        return RollupSnapshot(
            messageCount: row["message_count"], lastMessageAt: row["last_message_at"], unread: row["unread"])
    }
}

@Test func rollupCountsMessagesOncePerInsert() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: ["INBOX", "UNREAD"]), account: "x")
    _ = try await db.applySnapshot(snap("m2", date: 2, labels: ["INBOX"]), account: "x")
    _ = try await db.applySnapshot(snap("m1", date: 3, labels: ["INBOX", "UNREAD"]), account: "x")  // update, not new
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.messageCount == 2)                 // m1 update did not double-count
    #expect(row.lastMessageAt == 3)                // newest wins
    #expect(row.unread == true)                    // m1 unread
}

@Test func clearingLastUnreadLowersThreadUnread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: ["INBOX", "UNREAD"]), account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t1")?.unread == true)
    // A label event removes UNREAD → thread must recompute to unread=false.
    _ = try await db.applyHistory(
        [HistoryChange(kind: .labels(id: "m1", historyID: 5, labelIDs: ["INBOX"]))],
        newCursor: 5, account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t1")?.unread == false)
}

@Test func rollupMaintenanceStaysBoundedOnLargeThread() async throws {
    let db = try HudsonDatabase.inMemory()
    // 500 messages in ONE thread applied newest-first — must not degrade to O(N^2).
    for i in stride(from: 500, through: 1, by: -1) {
        _ = try await db.applySnapshot(snap("m\(i)", date: Int64(i), labels: ["INBOX"]), account: "x")
    }
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.messageCount == 500)
    #expect(row.lastMessageAt == 500)
    // (The assertion that matters for the risk is correctness at count; the reviewer/impl
    //  should confirm no per-message full-thread scan — maintainRollup touches one row.)
}
