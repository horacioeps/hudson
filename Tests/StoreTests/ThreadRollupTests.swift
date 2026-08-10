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
    let lastMessageID: String?
    let unread: Bool
    let inInbox: Bool
}

private func rollupRow(_ db: HudsonDatabase, account: String, thread: String) async throws -> RollupSnapshot? {
    try await db.writer.read { conn in
        guard let row = try Row.fetchOne(
            conn,
            sql: """
                SELECT message_count, last_message_at, last_message_id, unread, in_inbox
                FROM thread_rollup WHERE account_email = ? AND thread_id = ?
                """,
            arguments: [account, thread]
        ) else { return nil }
        return RollupSnapshot(
            messageCount: row["message_count"], lastMessageAt: row["last_message_at"],
            lastMessageID: row["last_message_id"], unread: row["unread"], inInbox: row["in_inbox"])
    }
}

/// Counts SQL statements traced on one connection — the O(N²)-regression
/// guard for `rollupMaintenanceStaysBoundedOnLargeThread` below. `@unchecked
/// Sendable`: the trace callback only ever fires synchronously on the
/// database's own serial queue, and this test drives it with sequential
/// `await`s (never concurrently), so there's no actual race to guard against.
private final class StatementCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
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

// MARK: - Fix round 1: batch-deduped update-path flag lowering

@Test func reappliedSnapshotThatDropsFlagsLowersThemViaBatchDedupedRecompute() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: ["INBOX", "UNREAD"]), account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t1")?.unread == true)
    #expect(try await rollupRow(db, account: "x", thread: "t1")?.inInbox == true)
    // Re-applying the SAME message (wasInsert == false) with both flags
    // dropped mirrors the routine cursor-expiry re-list path
    // (SyncEngine.pollHistory's 404 branch resets backfill, which then
    // re-`getMessage`s every already-known message as an UPDATE). Before
    // this fix, maintainRollup's OR-merge only ran on insert, so this
    // update left unread/in_inbox stuck at their prior (true) value.
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: []), account: "x")
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.unread == false)
    #expect(row.inInbox == false)
}

@Test func batchOfUpdatesToTheSameThreadDedupsToOneRecompute() async throws {
    let db = try HudsonDatabase.inMemory()
    // Three messages, one thread, all unread+inbox.
    _ = try await db.applySnapshots([
        snap("m1", date: 1, labels: ["INBOX", "UNREAD"]),
        snap("m2", date: 2, labels: ["INBOX", "UNREAD"]),
        snap("m3", date: 3, labels: ["INBOX", "UNREAD"]),
    ], account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t1")?.unread == true)
    // Re-apply ALL THREE as updates (one batch) with flags dropped — every
    // one of them touches the SAME thread, so the batch-dedup must still
    // land on the correct final (lowered) state, not just "correct if only
    // one update happens to touch a thread per batch".
    _ = try await db.applySnapshots([
        snap("m1", date: 1, labels: []),
        snap("m2", date: 2, labels: []),
        snap("m3", date: 3, labels: []),
    ], account: "x")
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.unread == false)
    #expect(row.inInbox == false)
    #expect(row.messageCount == 3)  // updates never double-count
}

// MARK: - Fix round 1: .deleted events maintain the rollup

@Test func deletingMessagesRebuildsOrDropsRollup() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t2", date: 1, labels: ["INBOX"], subject: "old"), account: "x")
    _ = try await db.applySnapshot(snap("m2", thread: "t2", date: 2, labels: ["INBOX", "UNREAD"], subject: "new"), account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t2")?.messageCount == 2)

    // Delete the newest message (m2): count drops, newest becomes m1, and
    // m1 carries no UNREAD so the thread's unread flag must also fall —
    // none of which `maintainRollup`'s incremental upsert can express.
    _ = try await db.applyHistoryChanges([HistoryChange(kind: .deleted(id: "m2"))], account: "x")
    let afterFirstDelete = try #require(try await rollupRow(db, account: "x", thread: "t2"))
    #expect(afterFirstDelete.messageCount == 1)
    #expect(afterFirstDelete.lastMessageID == "m1")
    #expect(afterFirstDelete.unread == false)

    // Delete the last remaining message — the rollup row is dropped
    // entirely (no messages left to summarize).
    _ = try await db.applyHistoryChanges([HistoryChange(kind: .deleted(id: "m1"))], account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t2") == nil)
}

@Test func deleteVanishedMessageAlsoRebuildsThreadRollup() async throws {
    // `deleteVanishedMessage` (the hydration-404 path) has the identical
    // tombstone+delete pattern as the `.deleted` history branch — same fix,
    // same coverage.
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t3", date: 1, labels: ["INBOX"]), account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t3")?.messageCount == 1)
    try await db.deleteVanishedMessage(id: "m1", account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t3") == nil)
}

// MARK: - Fix round 1: newest tie-break matches the bulk build (id DESC)

@Test func newestTieBreaksOnIdDescRegardlessOfApplyOrder() async throws {
    // Same internal_date twice, in both possible apply orders — the v3
    // bulk build always resolves a tie via `ORDER BY internal_date DESC,
    // id DESC`, so the incremental maintainer must agree regardless of
    // which one was applied last (not "last write wins" on a pure
    // timestamp tie).
    for (first, second) in [("m1", "m2"), ("m2", "m1")] {
        let db = try HudsonDatabase.inMemory()
        _ = try await db.applySnapshot(snap(first, thread: "t", date: 100, labels: ["INBOX"]), account: "x")
        _ = try await db.applySnapshot(snap(second, thread: "t", date: 100, labels: ["INBOX"]), account: "x")
        let lastMessageID = try await db.writer.read { conn in
            try String.fetchOne(
                conn, sql: "SELECT last_message_id FROM thread_rollup WHERE account_email='x' AND thread_id='t'")
        }
        #expect(lastMessageID == "m2")  // id DESC tie-break wins regardless of apply order
    }
}

// MARK: - The named biggest risk: bounded, not O(N²)

@Test func rollupMaintenanceStaysBoundedOnLargeThread() async throws {
    let db = try HudsonDatabase.inMemory()
    let counter = StatementCounter()
    try await db.writer.write { conn in
        conn.trace { _ in counter.increment() }
    }
    let messageCount = 2000
    let start = ContinuousClock.now
    // N messages in ONE thread applied newest-first — must not degrade to O(N^2).
    for i in stride(from: messageCount, through: 1, by: -1) {
        _ = try await db.applySnapshot(snap("m\(i)", date: Int64(i), labels: ["INBOX"]), account: "x")
    }
    let elapsed = start.duration(to: .now)
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.messageCount == messageCount)
    #expect(row.lastMessageAt == Int64(messageCount))
    // Two independent guards, because either shape of regression must fail
    // this test:
    //  1. Statement COUNT — catches a regression that issues MORE SQL
    //     statements per message as the thread grows (e.g. a per-message
    //     loop over other messages in the thread). All N applies here are
    //     INSERTs (distinct ids), so every one should take
    //     `maintainRollup`'s O(1) OR-merge path and never call
    //     `recomputeThreadFlags`/`recomputeThreadRollup` at all, and (Task 3)
    //     `FTSIndex.stubIndex`'s seq lookup/allocate + delete-then-reinsert
    //     is a fixed handful of statements too — measured at ~26
    //     statements/message: the ~10 from thread+message+label+rollup
    //     maintenance, plus FTS's seq SELECT+INSERT, a no-op DELETE (no
    //     prior row on a fresh insert), and one INSERT that SQLite
    //     internally amplifies across `fts_messages`'s several shadow
    //     tables — it carries three configured prefix indexes
    //     (`prefix='2 3 4'`), each maintaining its own b-tree. Still O(1)
    //     per message (confirmed by guard 2's wall-clock bound below
    //     staying flat), just a higher constant than before FTS existed.
    #expect(counter.count < messageCount * 35)
    //  2. Wall-clock — catches a regression that keeps a FIXED statement
    //     count per message but makes each statement scan the whole
    //     thread (e.g. calling the full-rebuild `recomputeThreadRollup`
    //     on every insert instead of `maintainRollup`'s O(1) upsert).
    //     Statement count alone is blind to this: SQLite's trace fires
    //     once per statement EXECUTION regardless of how many rows that
    //     execution internally scans, so a same-count-but-O(thread size)-
    //     per-call regression wouldn't move guard 1 at all — confirmed by
    //     hand-injecting exactly that regression (an unconditional
    //     `recomputeThreadFlags` call after every apply) during review:
    //     guard 1 stayed green (still ~10 statements/message) while this
    //     one went from well under a second to ~6.8s.
    #expect(elapsed < .seconds(5))
}
