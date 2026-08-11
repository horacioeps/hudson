import Testing
@testable import Store

/// Proves the reactive read spine works from a CONSUMER's vantage — a plain
/// async-iterator loop over `AsyncValueObservation`, the same shape the
/// SwiftUI view models (later tasks) will subscribe with. Lives in
/// `HudsonUITests` (not `StoreTests`) because it's exercising the
/// UI-consumption path, not the Store implementation itself.
///
/// Seeds directly via Store's public write APIs (`upsertAccount`/
/// `applySnapshot`) rather than `StoreTests`' `TestSeed` helper — that
/// helper lives in `Tests/StoreTests/Support/`, a different SwiftPM test
/// target, and there is no `DemoData` seeding helper yet for cross-target
/// reuse.
@Test func observeThreadEmitsThenReemitsAfterMarkingRead() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "m1", threadID: "t1", historyID: 1, internalDate: 1,
            fromLine: "sender@example.com", toLine: "you@example.com", subject: "Hello",
            snippet: "snippet", labelIDs: ["INBOX", "UNREAD"]),
        account: "a@b.com")

    var iterator = db.observeThread(threadID: "t1", account: "a@b.com").makeAsyncIterator()

    let first = try await iterator.next()
    #expect(first?.map(\.id) == ["m1"])
    #expect(first?.first?.labelIDs.contains("UNREAD") == true)

    // Optimistic "mark read": remove UNREAD. Same overlay `messageRow` reads,
    // so the observation must re-emit with UNREAD gone before any sync.
    try await db.enqueueMutation(messageID: "m1", labelID: "UNREAD", op: .remove,
                                 account: "a@b.com", now: 1)
    let second = try await iterator.next()
    #expect(second?.first?.labelIDs.contains("UNREAD") == false)
}
