import GmailKit
import Store
import Testing
@testable import SyncEngine

private func makeWorld(
    pages: [MessageListPage], messages: [String: GmailMessage]
) async throws -> (ScriptedGmail, HudsonDatabase, SyncEngine) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail(listPages: pages, messagesByID: messages)
    let engine = SyncEngine(api: gmail, database: database, account: "x")
    return (gmail, database, engine)
}

@Test func backfillRecordsCursorBeforeListing() async throws {
    let (gmail, database, engine) = try await makeWorld(pages: [], messages: [:])
    _ = try await engine.syncOnce()
    // Cursor must be recorded from profile BEFORE any list call (spec §4.1).
    let calls = await gmail.calls
    #expect(calls.first == "profile")
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 100)
    #expect(account.backfillState == "complete")  // empty mailbox completes at once
}

@Test func backfillPersistsMessagesAndResumesFromPageToken() async throws {
    let page1 = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1"), MessageRef(id: "m2", threadId: "t1")],
        nextPageToken: "p2", resultSizeEstimate: 3)
    let page2 = MessageListPage(
        messages: [MessageRef(id: "m3", threadId: "t2")], nextPageToken: nil,
        resultSizeEstimate: 3)
    let messages = [
        "m1": testMessage(id: "m1", historyID: "90"),
        "m2": testMessage(id: "m2", historyID: "91"),
        "m3": testMessage(id: "m3", threadID: "t2", historyID: "92"),
    ]
    let (_, database, engine) = try await makeWorld(pages: [page1, page2], messages: messages)

    // Limit to one page per pass: state must persist between passes.
    let first = try await engine.syncOnce(maxBackfillPages: 1)
    #expect(first.backfilledThisPass == 2)
    #expect(!first.backfillComplete)
    var account = try #require(try await database.primaryAccount())
    #expect(account.backfillPageToken == "p2")
    #expect(account.backfillState == "listing")

    let second = try await engine.syncOnce(maxBackfillPages: 1)
    #expect(second.backfilledThisPass == 1)
    #expect(second.backfillComplete)
    account = try #require(try await database.primaryAccount())
    #expect(account.backfillState == "complete")
    #expect(try await database.recentMessages(account: "x", limit: 10).count == 3)
}

@Test func concurrentSyncOnceIsSingleFlight() async throws {
    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 1)
    let (_, _, engine) = try await makeWorld(
        pages: [page], messages: ["m1": testMessage(id: "m1", historyID: "90")])
    async let a = engine.syncOnce()
    async let b = engine.syncOnce()
    let (ra, rb) = try await (a, b)
    // Exactly one pass did work; the other returned the empty coalesced report.
    #expect([ra.backfilledThisPass, rb.backfilledThisPass].sorted() == [0, 1])
}
