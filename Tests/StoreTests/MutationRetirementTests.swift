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
