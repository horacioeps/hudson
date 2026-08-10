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
    let (gmail, _, engine) = try await makeWorld(
        pages: [page], messages: ["m1": testMessage(id: "m1", historyID: "90")])
    async let a = engine.syncOnce()
    async let b = engine.syncOnce()
    let (ra, rb) = try await (a, b)
    // Exactly one pass did work; the other returned the empty coalesced report.
    #expect([ra.backfilledThisPass, rb.backfilledThisPass].sorted() == [0, 1])
    // Prove coalescing, not just a lucky count: the coalesced call never
    // touched the API at all — exactly one profile call, one list call.
    let calls = await gmail.calls
    #expect(calls.filter { $0 == "profile" }.count == 1)
    #expect(calls.filter { $0 == "list:start" }.count == 1)
}

@Test func backfillSkipsMessageThat404sAndStillAdvances() async throws {
    // "m2" is deliberately absent from `messages` — ScriptedGmail.getMessage
    // throws a 404 for unknown ids, modeling a message deleted between list
    // and get.
    let page = MessageListPage(
        messages: [
            MessageRef(id: "m1", threadId: "t1"), MessageRef(id: "m2", threadId: "t1"),
            MessageRef(id: "m3", threadId: "t1"),
        ], nextPageToken: nil, resultSizeEstimate: 3)
    let messages = [
        "m1": testMessage(id: "m1", historyID: "90"),
        "m3": testMessage(id: "m3", historyID: "92"),
    ]
    let (_, database, engine) = try await makeWorld(pages: [page], messages: messages)

    let report = try await engine.syncOnce()
    // The 404 on m2 didn't abort the pass: m1 and m3 still applied, and the
    // page still completed (token persisted, state advanced).
    #expect(report.backfilledThisPass == 2)
    #expect(report.backfillComplete)
    let account = try #require(try await database.primaryAccount())
    #expect(account.backfillState == "complete")
    #expect(try await database.recentMessages(account: "x", limit: 10).count == 2)
}
