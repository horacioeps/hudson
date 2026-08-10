import GmailKit
import Store
import Testing
@testable import SyncEngine

@Test func flushSendsModifyAndRetiresAfterCursorCatchesUp() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    try await db.writer.write { try $0.execute(sql: "UPDATE accounts SET history_cursor=100 WHERE email='x'") }
    // seed a message + an archive delta
    _ = try await db.applySnapshot(MessageSnapshot(id: "m1", threadID: "t", historyID: 90,
        internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)

    let gmail = ScriptedGmail()
    await gmail.setModifyResult(GmailMessageStub(id: "m1", historyId: "140"))  // modify returns historyId 140
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")

    let r1 = try await flusher.flushOnce()
    #expect(r1.flushed == 1)
    #expect(r1.retired == 0)                      // cursor(100) < 140, overlay stays → no flicker
    #expect(try await db.pendingMutations(account: "x").first?.state == "in_flight")

    try await db.writer.write { try $0.execute(sql: "UPDATE accounts SET history_cursor=140 WHERE email='x'") }
    let r2 = try await flusher.flushOnce()
    #expect(r2.retired == 1)
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}

@Test func terminalFailureDropsAndReconverges() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(MessageSnapshot(id: "m1", threadID: "t", historyID: 90,
        internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let gmail = ScriptedGmail()
    await gmail.setModifyError(GmailError.invalidRequest(status: 400, message: "bad label"))
    // The re-fetch after drop returns the true current message.
    await gmail.setMessages(["m1": testMessage(id: "m1", historyID: 200, labels: ["INBOX"])])
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")
    let r = try await flusher.flushOnce()
    #expect(r.dropped == 1)
    #expect(try await db.pendingMutations(account: "x").isEmpty)  // overlay gone, truth re-fetched
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(row.labelIDs.contains("INBOX"))  // converged to server truth (still in inbox)
}

// MARK: - Supplementary convergence coverage (beyond the brief's two tests)

/// Invariant #4: batchModify's 204 carries no historyId, so the retirement
/// gate has to come from a follow-up getProfile() ceiling. Also proves
/// coalescing: two messages sharing the identical (add,remove) key go out
/// as ONE batchModify, never as two singleton modifies.
@Test func batchModifyGroupsIdenticalLabelChangesAndGatesOnProfileCeiling() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    try await db.writer.write { try $0.execute(sql: "UPDATE accounts SET history_cursor=100 WHERE email='x'") }
    for id in ["m1", "m2"] {
        _ = try await db.applySnapshot(MessageSnapshot(id: id, threadID: "t", historyID: 90,
            internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]),
            account: "x")
        try await db.enqueueMutation(messageID: id, labelID: "INBOX", op: .remove, account: "x", now: 1)
    }
    let gmail = ScriptedGmail()
    await gmail.setProfileHistoryID("150")  // batchModify's 204 has no historyId — ceiling comes from here
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")

    let r1 = try await flusher.flushOnce()
    #expect(r1.flushed == 2)
    let batchCalls = await gmail.batchModifyCalls
    #expect(batchCalls.count == 1)                       // ONE batch, not two modifies
    #expect(Set(batchCalls[0].ids) == ["m1", "m2"])
    let modifyCalls = await gmail.modifyCalls
    #expect(modifyCalls.isEmpty)                          // never sent through the singleton path too
    #expect(r1.retired == 0)                              // cursor(100) hasn't caught up to the ceiling(150)

    try await db.writer.write { try $0.execute(sql: "UPDATE accounts SET history_cursor=150 WHERE email='x'") }
    let r2 = try await flusher.flushOnce()
    #expect(r2.retired == 2)
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}

/// Invariant #1 (never lost), the specific failure a hard review flagged:
/// a terminal failure on a COALESCED batch must not drop every member. If
/// Gmail 400s a batchModify because one member id is stale/bad, the OTHER
/// members' perfectly valid triage actions must still land, not be silently
/// discarded along with the bad one.
@Test func terminalBatchFailureIsolatesRetryPreservingValidMembers() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    try await db.writer.write { try $0.execute(sql: "UPDATE accounts SET history_cursor=100 WHERE email='x'") }
    for id in ["m1", "m2", "m3"] {
        _ = try await db.applySnapshot(MessageSnapshot(id: id, threadID: "t", historyID: 90,
            internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]),
            account: "x")
        try await db.enqueueMutation(messageID: id, labelID: "INBOX", op: .remove, account: "x", now: 1)
    }
    let gmail = ScriptedGmail()
    // The coalesced batch fails terminally — Gmail rejected the whole call
    // (e.g. one stale/invalid id riding along with two valid ones).
    await gmail.setBatchModifyError(GmailError.invalidRequest(status: 400, message: "bad request"))
    // Isolated retry: m1 and m3 succeed on their own; m2 is genuinely bad.
    await gmail.setModifyResult(GmailMessageStub(id: "m1", historyId: "140"), forID: "m1")
    await gmail.setModifyError(GmailError.invalidRequest(status: 400, message: "bad label"), forID: "m2")
    await gmail.setModifyResult(GmailMessageStub(id: "m3", historyId: "145"), forID: "m3")
    // The re-fetch after m2's drop returns the true current message.
    await gmail.setMessages(["m2": testMessage(id: "m2", historyID: 200, labels: ["INBOX"])])
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")

    let report = try await flusher.flushOnce()

    #expect(report.flushed == 2)  // m1 + m3, sent individually after isolation
    #expect(report.dropped == 1)  // m2 only — never the whole batch

    // One batch attempt, then exactly one modify per member.
    let batchCalls = await gmail.batchModifyCalls
    #expect(batchCalls.count == 1)
    let modifyCalls = await gmail.modifyCalls
    #expect(Set(modifyCalls.map(\.id)) == ["m1", "m2", "m3"])

    let pending = try await db.pendingMutations(account: "x")
    // m2's overlay is gone (dropped); m1's and m3's SURVIVE — not reverted.
    #expect(Set(pending.map(\.messageID)) == ["m1", "m3"])
    #expect(pending.allSatisfy { $0.state == "in_flight" })

    // m2 converged to server truth (still INBOX) instead of being silently
    // reverted or guessed.
    let row2 = try #require(try await db.message(id: "m2", account: "x")).row
    #expect(row2.labelIDs.contains("INBOX"))
}

/// Invariant #1 (never lost): a rate-limited/5xx/network failure must leave
/// the mutation `pending` — neither marked in_flight (which would imply it
/// was sent) nor dropped (which would discard real intent) — so the next
/// flush simply retries it.
@Test func transientErrorLeavesTheMutationPendingNotDropped() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(MessageSnapshot(id: "m1", threadID: "t", historyID: 90,
        internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let gmail = ScriptedGmail()
    await gmail.setModifyError(GmailError.server(status: 503))
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")

    await #expect(throws: GmailError.server(status: 503)) {
        try await flusher.flushOnce()
    }

    let pending = try await db.pendingMutations(account: "x")
    #expect(pending.count == 1)
    #expect(pending.first?.state == "pending")  // never touched — safe to resend next pass
}

/// Invariant #2 (never double-sent): a second concurrent flushOnce while one
/// is in flight coalesces to an empty report instead of re-sending.
@Test func concurrentFlushOnceIsSingleFlight() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(MessageSnapshot(id: "m1", threadID: "t", historyID: 90,
        internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let gmail = ScriptedGmail()
    await gmail.setModifyResult(GmailMessageStub(id: "m1", historyId: "140"))
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")

    async let a = flusher.flushOnce()
    async let b = flusher.flushOnce()
    let (ra, rb) = try await (a, b)
    // Exactly one pass did the send; the other coalesced to an empty report.
    #expect([ra.flushed, rb.flushed].sorted() == [0, 1])
    let modifyCalls = await gmail.modifyCalls
    #expect(modifyCalls.count == 1)  // never double-sent
}

/// The AsyncStream wakeup: `wake()` should drive `start()`'s loop into a
/// `flushOnce()` well before the next poll tick would otherwise fire.
@Test func wakeDrivesTheStartLoopIntoAFlush() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(MessageSnapshot(id: "m1", threadID: "t", historyID: 90,
        internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let gmail = ScriptedGmail()
    await gmail.setModifyResult(GmailMessageStub(id: "m1", historyId: "140"))
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")

    let loop = Task { await flusher.start() }
    flusher.wake()
    // Bounded poll instead of a fixed sleep — avoids flaking under load
    // while still capping the wait.
    for _ in 0..<200 {
        if try await db.pendingMutations(account: "x").first?.state == "in_flight" { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(try await db.pendingMutations(account: "x").first?.state == "in_flight")
    loop.cancel()
}
