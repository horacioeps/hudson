import GmailKit
import Store
import Testing
@testable import SyncEngine

/// Proves category splits need zero extra sync work: a message carrying a
/// Gmail `CATEGORY_*` label is just another label — M2 already persists
/// every label a message carries — and `thread_rollup.category`/`split_key`
/// pick it up automatically via `ThreadRollup.maintainRollup` (Task 7), with
/// no new sync-side code required.
@Test func categoryLabelPersistsThroughSyncAndDrivesSplitKeyForFree() async throws {
    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 1)
    let messages = [
        "m1": testMessage(id: "m1", historyID: "90", labels: ["INBOX", "CATEGORY_PROMOTIONS"]),
    ]
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail(listPages: [page], messagesByID: messages)
    let engine = SyncEngine(api: gmail, database: database, account: "x")

    _ = try await engine.syncOnce()

    // The label persists through applySnapshot — no special-casing needed.
    let row = try #require(try await database.recentMessages(account: "x", limit: 10).first)
    #expect(row.labelIDs.contains("CATEGORY_PROMOTIONS"))

    // ...and the rollup's category/split_key reflect it, with zero rules configured.
    let thread = try #require(
        try await database.inboxThreads(account: "x", split: nil, limit: 10).first)
    #expect(thread.category == "promotions")
    #expect(thread.splitKey == "promotions")
}
