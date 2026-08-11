import Foundation
import GRDB
import Testing
@testable import Store

private func snap(
    _ id: String, thread: String = "t1", subject: String = "Quarterly report",
    from: String = "ada@x.com", to: String = "you@x.com", labels: [String] = ["INBOX"],
    date: Int64 = 1
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: from, toLine: to, subject: subject, snippet: "sn", labelIDs: labels)
}

private func body(_ plainText: String) -> SanitizedBody {
    SanitizedBody(
        rawHTML: nil, plainText: plainText, sanitizerVersion: Sanitizer.version,
        cidReferences: [], remoteURLs: [])
}

private func matchCount(_ db: HudsonDatabase, _ query: String) async throws -> Int {
    try await db.writer.read { conn in
        try Int.fetchOne(
            conn, sql: "SELECT COUNT(*) FROM fts_messages WHERE fts_messages MATCH ?",
            arguments: [query]) ?? 0
    }
}

// MARK: - RED: subject searchable after apply

@Test func subjectSearchableAfterApply() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    #expect(try await matchCount(db, "quarter*") == 1)
}

@Test func fromAndToAreSearchable() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", from: "ada@example.com", to: "bob@example.com"), account: "x")
    #expect(try await matchCount(db, "ada*") == 1)
    #expect(try await matchCount(db, "bob*") == 1)
}

// MARK: - RED: body searchable after saveBody

@Test func bodySearchableAfterSaveBody() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Hello"), account: "x")
    #expect(try await matchCount(db, "numbers") == 0)
    try await db.saveBody(messageID: "m1", account: "x", body: body("the numbers are in"))
    #expect(try await matchCount(db, "numbers") == 1)
    // Subject must still be intact after the body-only reindex.
    #expect(try await matchCount(db, "hello*") == 1)
}

@Test func reindexBodyReplacesPriorBodyRatherThanAppending() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.saveBody(messageID: "m1", account: "x", body: body("original wording"))
    #expect(try await matchCount(db, "original") == 1)
    try await db.saveBody(messageID: "m1", account: "x", body: body("revised wording"))
    #expect(try await matchCount(db, "original") == 0)
    #expect(try await matchCount(db, "revised") == 1)
}

// MARK: - RED: a metadata-only re-stub must not wipe an already-indexed body

@Test func metadataReapplyPreservesIndexedBody() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Hello", date: 1), account: "x")
    try await db.saveBody(messageID: "m1", account: "x", body: body("the numbers are in"))
    #expect(try await matchCount(db, "numbers") == 1)
    // Same message re-applied as an update (e.g. the cursor-expiry re-list
    // path) mirrors a routine metadata refresh — `stubIndex` must LEFT JOIN
    // the current body back in rather than blanking it.
    _ = try await db.applySnapshot(snap("m1", subject: "Hello updated", date: 1), account: "x")
    #expect(try await matchCount(db, "numbers") == 1)
    #expect(try await matchCount(db, "updated*") == 1)
}

// MARK: - RED: gone after delete

@Test func goneAfterDeleteVanishedMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    #expect(try await matchCount(db, "quarter*") == 1)
    try await db.deleteVanishedMessage(id: "m1", account: "x")
    #expect(try await matchCount(db, "quarter*") == 0)
    let seqCount = try await db.writer.read { conn in
        try Int.fetchOne(
            conn, sql: "SELECT COUNT(*) FROM message_seq WHERE account_email = ? AND message_id = ?",
            arguments: ["x", "m1"]) ?? -1
    }
    #expect(seqCount == 0)
}

@Test func goneAfterDeletedHistoryEvent() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    _ = try await db.applyHistoryChanges([HistoryChange(kind: .deleted(id: "m1"))], account: "x")
    #expect(try await matchCount(db, "quarter*") == 0)
}

// MARK: - M5 Task 7 carry-forward: orphaned mutation_queue rows on message delete

@Test func deleteVanishedMessageClearsThatMessagesPendingMutations() async throws {
    // Identical concern as the `.deleted` history-event branch (see
    // HistoryApplyTests' twin) — `deleteVanishedMessage` (the hydration-404
    // path) is the other place a message row disappears without any FK
    // cascade covering mutation_queue.
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    #expect(try await db.pendingMutations(account: "x").count == 1)
    try await db.deleteVanishedMessage(id: "m1", account: "x")
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}

// MARK: - M5 Task 7 carry-forward: reindexBody must not allocate an orphan seq

@Test func reindexBodyDoesNotAllocateASeqForAMessageThatNoLongerExists() async throws {
    let db = try HudsonDatabase.inMemory()
    // `reindexBody`'s "message row is gone" guard is unreachable via its
    // only real caller, `saveBody`: `message_bodies`' FK to `messages`
    // (enforced — `foreignKeysEnabled = true`) would already abort that
    // same transaction's `INSERT INTO message_bodies` before `reindexBody`
    // ever ran, so the scenario its doc comment describes ("deleted between
    // hydration fetch and save") can't reach this guard THROUGH saveBody.
    // Exercised directly instead — the guard is still worth having
    // defensively (a hypothetical future caller with no such FK ahead of
    // it), and this is the only way to actually drive the branch.
    try await db.writer.write { conn in
        try FTSIndex.reindexBody(messageID: "ghost", account: "x", plainText: "late body", db: conn)
    }
    let seqCount = try await db.writer.read { conn in
        try Int.fetchOne(
            conn, sql: "SELECT COUNT(*) FROM message_seq WHERE account_email = ? AND message_id = ?",
            arguments: ["x", "ghost"]) ?? -1
    }
    // Before the fix: `seq(for:)` runs FIRST (allocating a message_seq row
    // for "ghost") and only THEN does the existence check fail and return
    // early — leaving that row orphaned with no fts_messages entry and no
    // further cleanup call. After: the existence check runs first, so a
    // miss never allocates anything.
    #expect(seqCount == 0)
}

// MARK: - Reused rowid: seq() is a stable lookup-or-allocate, not a fresh id per call

@Test func seqIsStableAcrossRepeatedInsertsOfTheSameMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 1), account: "x")
    _ = try await db.applySnapshot(snap("m1", subject: "changed", date: 1), account: "x")
    let seqCount = try await db.writer.read { conn in
        try Int.fetchOne(
            conn, sql: "SELECT COUNT(*) FROM message_seq WHERE account_email = ? AND message_id = ?",
            arguments: ["x", "m1"]) ?? -1
    }
    #expect(seqCount == 1)
    let ftsCount = try await db.writer.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM fts_messages") ?? -1
    }
    #expect(ftsCount == 1)
}

// MARK: - integrity-check: randomized insert/reindex/delete sequence

@Test func integrityCheckPassesAfterRandomizedOperations() async throws {
    let db = try HudsonDatabase.inMemory()
    var alive = Set<String>()
    for i in 0..<200 {
        let id = "m\(i % 40)"
        switch Int.random(in: 0..<3) {
        case 0:
            // Once a message is deleted (tombstoned), the §4.2 version guard
            // permanently blocks re-inserting that id — a late snapshot must
            // not resurrect it. So `alive` only gains `id` back when the
            // apply is genuinely `.applied`, not merely attempted.
            let outcome = try await db.applySnapshot(
                snap(id, subject: "Subject \(i)", date: Int64(i)), account: "x")
            if outcome == .applied {
                alive.insert(id)
            }
        case 1:
            if alive.contains(id) {
                try await db.saveBody(messageID: id, account: "x", body: body("body text \(i)"))
            }
        default:
            if alive.contains(id) {
                try await db.deleteVanishedMessage(id: id, account: "x")
                alive.remove(id)
            }
        }
    }
    // Must not throw — the internal FTS5 b-tree structures must still match
    // the stored row content after this sequence of deletes/reinserts.
    try await db.writer.write { conn in
        try conn.execute(sql: "INSERT INTO fts_messages(fts_messages) VALUES('integrity-check')")
    }
    let ftsCount = try await db.writer.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM fts_messages") ?? -1
    }
    #expect(ftsCount == alive.count)
    let seqCount = try await db.writer.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM message_seq") ?? -1
    }
    #expect(seqCount == alive.count)
}
