import Testing
@testable import Store

private func account(_ db: HudsonDatabase, cursor: Int64?) async throws {
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    if let cursor {
        try await db.writer.write { try $0.execute(
            sql: "UPDATE accounts SET history_cursor = ? WHERE email = 'x'", arguments: [cursor]) }
    }
}

@Test func retiresOnlyWhenCursorReachesExpectedHistory() async throws {
    let db = try HudsonDatabase.inMemory()
    try await account(db, cursor: 100)
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let pending = try await db.claimPendingBatch(account: "x", limit: 10)
    try await db.markInFlight(mutationIDs: pending.map(\.id), expectedHistoryID: 150, account: "x")

    // Cursor still behind 150 → nothing retires (the echo hasn't landed; retiring now would flicker).
    #expect(try await db.retireConfirmedMutations(account: "x") == 0)
    #expect(try await db.pendingMutations(account: "x").count == 1)

    // Cursor catches up → retire.
    try await db.writer.write { try $0.execute(
        sql: "UPDATE accounts SET history_cursor = 150 WHERE email = 'x'") }
    #expect(try await db.retireConfirmedMutations(account: "x") == 1)
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}

@Test func dropRemovesWithoutGate() async throws {
    let db = try HudsonDatabase.inMemory()
    try await account(db, cursor: 100)
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let id = try await db.pendingMutations(account: "x").first!.id
    try await db.dropMutation(id: id, account: "x")
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}

@Test func opposingEnqueueAgainstInFlightRowOverlaysForwardInsteadOfDeleting() async throws {
    // Regression for the M3 final-review Fix 1 lost update: archive (enqueue
    // remove) → the flusher sends it and marks it in_flight (cursor hasn't
    // caught up yet, so it can't retire) → unarchive (enqueue add) must NOT
    // find the in_flight remove row, delete it, and return — that would
    // silently lose the unarchive (nothing left in the queue to send it).
    let db = try HudsonDatabase.inMemory()
    try await account(db, cursor: 100)
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let claimed = try await db.claimPendingBatch(account: "x", limit: 10)
    try await db.markInFlight(mutationIDs: claimed.map(\.id), expectedHistoryID: 140, account: "x")

    // Opposite op arrives while the row is still in_flight (cursor at 100 < 140).
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .add, account: "x", now: 2)

    let pending = try await db.pendingMutations(account: "x")
    #expect(pending.count == 1)  // NOT an empty queue — the unarchive must survive
    let row = try #require(pending.first(where: { $0.messageID == "m1" }))
    #expect(row.op == .add)
    #expect(row.state == "pending")
    #expect(row.expectedHistoryID == nil)

    // Effective read shows INBOX present again (the overlay reflects the new intent).
    let snap = MessageSnapshot(
        id: "m1", threadID: "t", historyID: 1, internalDate: 1000,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: [])
    _ = try await db.applySnapshot(snap, account: "x")
    let effective = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(effective.labelIDs.contains("INBOX"))
}

@Test func retireReturnsZeroWhenCursorIsNull() async throws {
    let db = try HudsonDatabase.inMemory()
    try await account(db, cursor: nil)  // no cursor set yet
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let pending = try await db.claimPendingBatch(account: "x", limit: 10)
    try await db.markInFlight(mutationIDs: pending.map(\.id), expectedHistoryID: 150, account: "x")

    // Cursor is NULL → retire returns 0, does not throw.
    #expect(try await db.retireConfirmedMutations(account: "x") == 0)
    #expect(try await db.pendingMutations(account: "x").count == 1)
}
