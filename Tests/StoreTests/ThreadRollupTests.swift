import GRDB
import Testing
@testable import Store

private func snap(
    _ id: String, thread: String = "t1", date: Int64, labels: [String], subject: String = "s",
    fromLine: String = "ada@x.com"
) -> MessageSnapshot {
    MessageSnapshot(id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: fromLine, toLine: "you@x.com", subject: subject, snippet: "sn", labelIDs: labels)
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
    let fromSummary: String
}

private func rollupRow(_ db: HudsonDatabase, account: String, thread: String) async throws -> RollupSnapshot? {
    try await db.writer.read { conn in
        guard let row = try Row.fetchOne(
            conn,
            sql: """
                SELECT message_count, last_message_at, last_message_id, unread, in_inbox, from_summary
                FROM thread_rollup WHERE account_email = ? AND thread_id = ?
                """,
            arguments: [account, thread]
        ) else { return nil }
        return RollupSnapshot(
            messageCount: row["message_count"], lastMessageAt: row["last_message_at"],
            lastMessageID: row["last_message_id"], unread: row["unread"], inInbox: row["in_inbox"],
            fromSummary: row["from_summary"])
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
    // Inserts `n` messages into ONE thread, newest-first, into a fresh
    // in-memory db — returns the statement count (guard 1) and wall-clock
    // elapsed (guard 2's raw material). Factored out so guard 2 can compare
    // two different thread sizes on the SAME run, rather than compare one
    // size against a fixed absolute number.
    func insertLargeThread(_ n: Int) async throws -> (statementCount: Int, elapsed: Duration, row: RollupSnapshot?) {
        let db = try HudsonDatabase.inMemory()
        let counter = StatementCounter()
        try await db.writer.write { conn in
            conn.trace { _ in counter.increment() }
        }
        let start = ContinuousClock.now
        for i in stride(from: n, through: 1, by: -1) {
            _ = try await db.applySnapshot(snap("m\(i)", date: Int64(i), labels: ["INBOX"]), account: "x")
        }
        let elapsed = start.duration(to: .now)
        return (counter.count, elapsed, try await rollupRow(db, account: "x", thread: "t1"))
    }

    let messageCount = 2000
    let full = try await insertLargeThread(messageCount)
    #expect(full.row?.messageCount == messageCount)
    #expect(full.row?.lastMessageAt == Int64(messageCount))
    // Two independent guards, because either shape of regression must fail
    // this test:
    //  1. Statement COUNT — catches a regression that issues MORE SQL
    //     statements per message as the thread grows (e.g. a per-message
    //     loop over other messages in the thread). All N applies here are
    //     INSERTs (distinct ids), so every one should take
    //     `maintainRollup`'s O(1) OR-merge path and never call
    //     `recomputeThreadFlags`/`recomputeThreadRollup` at all, and (Task 3)
    //     `FTSIndex.stubIndex`'s seq lookup/allocate + delete-then-reinsert
    //     is a fixed handful of statements too — measured at ~28
    //     statements/message: the ~11 from thread+message+label+rollup
    //     maintenance (Task 9b adds one indexed `from_summary` point
    //     lookup per insert — see `ThreadRollup.maintainRollup`), plus
    //     FTS's seq SELECT+INSERT, a no-op DELETE (no
    //     prior row on a fresh insert), and one INSERT that SQLite
    //     internally amplifies across `fts_messages`'s several shadow
    //     tables — it carries three configured prefix indexes
    //     (`prefix='2 3 4'`), each maintaining its own b-tree. Still O(1)
    //     per message (confirmed by guard 2's ratio staying flat), just a
    //     higher constant than before FTS existed. Deterministic and
    //     machine-speed-independent by construction (a statement count
    //     doesn't care how fast the runner is), so this one keeps its
    //     original absolute-bound shape.
    #expect(full.statementCount < messageCount * 35)
    //  2. Wall-clock RATIO — catches a regression that keeps a FIXED
    //     statement count per message but makes each statement scan the
    //     whole thread (e.g. calling the full-rebuild `recomputeThreadRollup`
    //     on every insert instead of `maintainRollup`'s O(1) upsert).
    //     Statement count alone is blind to this: SQLite's trace fires once
    //     per statement EXECUTION regardless of how many rows that
    //     execution internally scans, so a same-count-but-O(thread size)-
    //     per-call regression wouldn't move guard 1 at all — confirmed by
    //     hand-injecting exactly that regression (an unconditional
    //     `recomputeThreadFlags` call after every apply) during review:
    //     guard 1 stayed green while wall-clock cost went from well under a
    //     second to several seconds.
    //
    //     Fix round (M5 Task 7 carry-forward): the ORIGINAL form of this
    //     guard asserted an ABSOLUTE bound (`elapsed < .seconds(5)`) on the
    //     2000-message run above — a bet on the CI runner's speed, and
    //     therefore flaky under machine load independent of any real
    //     regression. Comparing the SAME algorithm at two thread sizes on
    //     the SAME runner, in the SAME test, cancels the runner's absolute
    //     speed out of the assertion entirely: O(1)-per-message maintenance
    //     means total cost is O(N), so quadrupling the thread size should
    //     roughly quadruple wall-clock cost, not the ~16x a reintroduced
    //     O(N²) per-message full-thread scan would produce.
    let quarter = try await insertLargeThread(messageCount / 4)
    // Linear (O(N)) scaling predicts ~4x; true O(N²) predicts ~16x. 10x is
    // the threshold: comfortably clear of linear (leaves headroom for
    // ordinary timing noise, including on a loaded/throttled CI runner —
    // the *ratio* stays close to 4x regardless of the runner's absolute
    // speed), while still decisively short of the ~16x an O(N²) regression
    // would produce.
    #expect(full.elapsed < quarter.elapsed * 10)
}

// MARK: - Fix wave 2: batch-deduped .labels/.deleted rollup recomputes

@Test func batchOfLabelEventsOnOneLargeThreadStaysBoundedNotQuadratic() async throws {
    let db = try HudsonDatabase.inMemory()
    let messageCount = 1500
    // Only the VERY LAST message (by internal_date, the end of the indexed
    // scan `recomputeThreadFlags`'s EXISTS query walks) carries UNREAD/
    // INBOX — every other message carries neither. This forces the
    // per-thread EXISTS scan to walk (nearly) the whole thread to resolve
    // on every call, so an inline per-event recompute (the pre-fix
    // behavior) pays that near-full scan `eventCount` times.
    var snapshots: [MessageSnapshot] = []
    for i in 1...messageCount {
        let labels = (i == messageCount) ? ["INBOX", "UNREAD"] : []
        snapshots.append(snap("m\(i)", date: Int64(i), labels: labels))
    }
    _ = try await db.applySnapshots(snapshots, account: "x")

    let eventCount = 400
    // K `.labels` events, all touching the SAME thread (different early
    // messages, each just re-affirming its already-empty label set at a
    // higher historyID) — ONE batch, ONE `applyHistoryChanges` call.
    let changes = (1...eventCount).map { i in
        HistoryChange(kind: .labels(id: "m\(i)", historyID: Int64(i) + 10_000, labelIDs: []))
    }

    let counter = StatementCounter()
    try await db.writer.write { conn in
        conn.trace { _ in counter.increment() }
    }
    let start = ContinuousClock.now
    _ = try await db.applyHistoryChanges(changes, account: "x")
    let elapsed = start.duration(to: .now)

    // Regression guard: per-event inline recompute (pre-fix) runs
    // `recomputeThreadFlags` `eventCount` times, each a near-full-thread
    // scan — O(eventCount * messageCount), which blows past both bounds
    // below at this thread size. The fix defers to ONE recompute after the
    // loop — O(messageCount + eventCount) total, well within both.
    #expect(elapsed < .seconds(3))
    #expect(counter.count < eventCount * 25)

    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.unread == true)
    #expect(row.inInbox == true)
}

@Test func batchOfDeleteEventsOnOneLargeThreadStaysBoundedNotQuadratic() async throws {
    let db = try HudsonDatabase.inMemory()
    let messageCount = 1500
    var snapshots: [MessageSnapshot] = []
    for i in 1...messageCount {
        snapshots.append(
            snap("m\(i)", date: Int64(i), labels: ["INBOX"], fromLine: "sender\(i)@x.com"))
    }
    _ = try await db.applySnapshots(snapshots, account: "x")

    let eventCount = 60
    // Delete the oldest `eventCount` messages in ONE batch. Per-event
    // inline recompute (pre-fix) runs the HEAVY full
    // `recomputeThreadRollup` (survivor from_line fetch + Swift-side
    // dedup over up to `messageCount` rows) once PER event — O(eventCount
    // * messageCount). Distinct `fromLine`s per message (above) mean this
    // Swift dedup loop can't short-circuit early. The fix defers to ONE
    // rebuild after the loop — O(messageCount + eventCount).
    let changes = (1...eventCount).map { i in HistoryChange(kind: .deleted(id: "m\(i)")) }

    let counter = StatementCounter()
    try await db.writer.write { conn in
        conn.trace { _ in counter.increment() }
    }
    let start = ContinuousClock.now
    _ = try await db.applyHistoryChanges(changes, account: "x")
    let elapsed = start.duration(to: .now)

    #expect(elapsed < .seconds(3))
    #expect(counter.count < eventCount * 25)

    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.messageCount == messageCount - eventCount)
}

// MARK: - Task 9b: from_summary (sender display names, append-dedup)

@Test func senderDisplayNameExtractsDisplayNameOrLocalPart() {
    // `Display Name <email>` → the display name, quotes stripped.
    #expect(ThreadRollup.senderDisplayName(fromLine: "Ada Lovelace <ada@example.com>") == "Ada Lovelace")
    #expect(ThreadRollup.senderDisplayName(fromLine: "\"Ada Lovelace\" <ada@example.com>") == "Ada Lovelace")
    // Bare email → the local-part.
    #expect(ThreadRollup.senderDisplayName(fromLine: "ada@example.com") == "ada")
    // Angle brackets with no display name → falls back to the email's local-part.
    #expect(ThreadRollup.senderDisplayName(fromLine: " <ada@example.com>") == "ada")
    // No "@" at all (still angle-bracketed) → the bracketed text verbatim.
    #expect(ThreadRollup.senderDisplayName(fromLine: "<not-an-email>") == "not-an-email")
    // Empty input → empty output.
    #expect(ThreadRollup.senderDisplayName(fromLine: "") == "")
    #expect(ThreadRollup.senderDisplayName(fromLine: "   ") == "")
}

@Test func senderDisplayNameNeverCrashesOnMalformedInput() {
    // `from_line` comes straight from sender-controlled mail headers —
    // this must degrade gracefully (some string back, or "") rather than
    // crash/throw, no matter how it's mangled.
    let malformed = [
        "<>", ">ada@example.com<", "<<<>>>", "@", "@@@", "\"unterminated",
        "Ada <ada@", "<ada@example.com", "ada@example.com>", "<>Ada Lovelace<>",
    ]
    for line in malformed {
        _ = ThreadRollup.senderDisplayName(fromLine: line)
    }
}

@Test func freshThreadFromSummaryIsSenderDisplayName() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX"], fromLine: "Ada Lovelace <ada@example.com>"), account: "x")
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.fromSummary == "Ada Lovelace")
}

@Test func secondMessageFromDifferentSenderAppendsDeduped() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX"], fromLine: "Ada Lovelace <ada@example.com>"), account: "x")
    _ = try await db.applySnapshot(
        snap("m2", date: 2, labels: ["INBOX"], fromLine: "Bob <bob@example.com>"), account: "x")
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.fromSummary == "Ada Lovelace, Bob")
}

@Test func secondMessageFromSameSenderDoesNotDuplicate() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX"], fromLine: "Ada Lovelace <ada@example.com>"), account: "x")
    _ = try await db.applySnapshot(
        snap("m2", date: 2, labels: ["INBOX"], fromLine: "Ada Lovelace <ada@example.com>"), account: "x")
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.fromSummary == "Ada Lovelace")
}

@Test func fromSummaryCapsAtMostRecentDistinctSenders() async throws {
    // A 4th distinct sender pushes the from_summary past its cap of 3 —
    // the OLDEST distinct name (Ada) is dropped, keeping the most
    // recently-seen distinct senders.
    let db = try HudsonDatabase.inMemory()
    let senders = [
        "Ada <ada@x.com>", "Bob <bob@x.com>", "Cara <cara@x.com>", "Dee <dee@x.com>",
    ]
    for (i, fromLine) in senders.enumerated() {
        _ = try await db.applySnapshot(
            snap("m\(i)", date: Int64(i), labels: ["INBOX"], fromLine: fromLine), account: "x")
    }
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.fromSummary == "Bob, Cara, Dee")
}

@Test func updateToExistingMessageLeavesFromSummaryUnchanged() async throws {
    // A same-message UPDATE (wasInsert == false) never adds a new sender —
    // only a genuinely new message can (see `maintainRollup`'s doc comment).
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX"], fromLine: "Ada Lovelace <ada@example.com>"), account: "x")
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX"], fromLine: "Someone Else <else@example.com>"), account: "x")
    let row = try #require(try await rollupRow(db, account: "x", thread: "t1"))
    #expect(row.fromSummary == "Ada Lovelace")
}

@Test func recomputeAfterDeleteRebuildsFromSummaryFromSurvivors() async throws {
    // `recomputeThreadRollup` (the full, authoritative rebuild used after a
    // `.deleted` event) must drop a sender whose only message was deleted —
    // `maintainRollup`'s append-only upsert can never express a removal.
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", thread: "t2", date: 1, labels: ["INBOX"], fromLine: "Ada Lovelace <ada@example.com>"),
        account: "x")
    _ = try await db.applySnapshot(
        snap("m2", thread: "t2", date: 2, labels: ["INBOX"], fromLine: "Bob <bob@example.com>"),
        account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t2")?.fromSummary == "Ada Lovelace, Bob")

    _ = try await db.applyHistoryChanges([HistoryChange(kind: .deleted(id: "m2"))], account: "x")
    #expect(try await rollupRow(db, account: "x", thread: "t2")?.fromSummary == "Ada Lovelace")
}

@Test func inboxThreadsReturnsPopulatedFromSummary() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX"], fromLine: "Ada Lovelace <ada@example.com>"), account: "x")
    let rows = try await db.inboxThreads(account: "x", split: nil, limit: 10)
    #expect(rows.first?.fromSummary == "Ada Lovelace")
}
