import Foundation
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

// MARK: - Sync window (backfill is bounded to mail around the connect date)

/// Builds a world whose account consented at a FIXED instant, so a test can
/// assert the exact `after:` anchor backfill derives from it.
private func makeWindowedWorld(
    consentedAt: Date, lookbackDays: Int, pages: [MessageListPage],
    messages: [String: GmailMessage]
) async throws -> (ScriptedGmail, SyncEngine) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: consentedAt)
    let gmail = ScriptedGmail(listPages: pages, messagesByID: messages)
    let engine = SyncEngine(
        api: gmail, database: database, account: "x", backfillLookbackDays: lookbackDays)
    return (gmail, engine)
}

@Test func backfillBoundsEveryPageToTheSameWindowAnchor() async throws {
    let consentedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let page1 = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: "p2",
        resultSizeEstimate: 2)
    let page2 = MessageListPage(
        messages: [MessageRef(id: "m2", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 2)
    let (gmail, engine) = try await makeWindowedWorld(
        consentedAt: consentedAt, lookbackDays: 90, pages: [page1, page2],
        messages: [
            "m1": testMessage(id: "m1", historyID: "90"),
            "m2": testMessage(id: "m2", historyID: "91"),
        ])

    // Two separate passes, so the second resumes from a stored page token —
    // the case a sliding `newer_than:90d` would silently corrupt.
    _ = try await engine.syncOnce(maxBackfillPages: 1)
    _ = try await engine.syncOnce(maxBackfillPages: 1)

    let expected = "after:\(1_750_000_000 - 90 * 86_400)"
    let queries = await gmail.listQueries
    // Anchored to consentedAt, NOT to now(): both pages carry the identical
    // filter, so the resumed listing sees exactly the set its token came from.
    #expect(queries == [expected, expected])
}

@Test func zeroLookbackBackfillsTheWholeMailbox() async throws {
    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 1)
    let (gmail, engine) = try await makeWindowedWorld(
        consentedAt: Date(timeIntervalSince1970: 1_750_000_000), lookbackDays: 0,
        pages: [page], messages: ["m1": testMessage(id: "m1", historyID: "90")])

    _ = try await engine.syncOnce()

    // The escape hatch: no window means no `q` at all (an unbounded listing),
    // which is what every pre-window test and a full-archive re-sync expect.
    let queries = await gmail.listQueries
    #expect(queries == [nil])
}
