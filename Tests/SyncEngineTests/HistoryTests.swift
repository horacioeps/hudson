import Foundation
import GmailKit
import Store
import Testing
@testable import SyncEngine

private func makeSyncedWorld() async throws -> (ScriptedGmail, HudsonDatabase, SyncEngine) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail()
    let engine = SyncEngine(api: gmail, database: database, account: "x")
    _ = try await engine.syncOnce()  // records cursor 100, completes empty backfill
    return (gmail, database, engine)
}

@Test func historyEventsApplyInOrderAndAdvanceCursor() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistory([historyPage("""
        {"historyId": "120", "history": [
          {"id": "110", "messagesAdded": [{"message":
            {"id": "m1", "threadId": "t1", "historyId": "110",
             "internalDate": "1000", "labelIds": ["INBOX", "UNREAD"], "snippet": "sn",
             "payload": {"headers": [{"name": "Subject", "value": "s"}]}}}]},
          {"id": "115", "labelsRemoved": [{"message":
            {"id": "m1", "threadId": "t1", "historyId": "115", "labelIds": ["INBOX"]}}]}
        ]}
        """)])
    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 2)
    let row = try #require(try await database.recentMessages(account: "x", limit: 1).first)
    #expect(row.labelIDs == ["INBOX"])  // UNREAD removed by the later event
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 120)
}

@Test func unknownLabelEventHydratesTheMessage() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setMessages(["mX": testMessage(id: "mX", historyID: "118")])
    await gmail.setHistory([historyPage("""
        {"historyId": "119", "history": [
          {"id": "118", "labelsAdded": [{"message":
            {"id": "mX", "threadId": "t9", "historyId": "118", "labelIds": ["INBOX"]}}]}
        ]}
        """)])
    _ = try await engine.syncOnce()
    // The unknown id was hydrated via metadata get, not applied blind.
    #expect(try await database.recentMessages(account: "x", limit: 5).map(\.id) == ["mX"])
}

@Test func expiredCursorResetsBackfillAndRefreshesCursor() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistoryError(GmailError.invalidRequest(status: 404, message: "expired"))
    await gmail.setProfileHistoryID("500")
    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 0)
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 500)       // fresh cursor recorded
    #expect(account.backfillState != "complete")  // re-list scheduled
}

@Test func startHistoryIDStaysFixedAcrossMultiPagePoll() async throws {
    // Regression: pollHistory must NOT mutate its startHistoryID between
    // pages of the same pass. Gmail page tokens continue the listing they
    // were created by, so pairing "p2" with a startHistoryId that changed
    // since page 1 is undefined — `start` must stay the pass's original
    // cursor ("100" here) for every page.
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistory([
        historyPage("""
            {"historyId": "110", "nextPageToken": "p2", "history": [
              {"id": "105", "messagesAdded": [{"message":
                {"id": "m1", "threadId": "t1", "historyId": "105",
                 "internalDate": "1000", "labelIds": ["INBOX"], "snippet": "sn",
                 "payload": {"headers": [{"name": "Subject", "value": "s"}]}}}]}
            ]}
            """),
        historyPage("""
            {"historyId": "120", "history": [
              {"id": "118", "messagesAdded": [{"message":
                {"id": "m2", "threadId": "t2", "historyId": "118",
                 "internalDate": "2000", "labelIds": ["INBOX"], "snippet": "sn2",
                 "payload": {"headers": [{"name": "Subject", "value": "s2"}]}}}]}
            ]}
            """),
    ])
    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 2)

    // makeSyncedWorld's own pass already made one listHistory call; this
    // pass's two page calls are the last two recorded.
    let calls = await gmail.historyCalls
    let thisPassCalls = Array(calls.suffix(2))
    #expect(thisPassCalls[0] == HistoryCall(startHistoryID: "100", pageToken: nil))
    // The regression itself: page 2's call still carries the ORIGINAL cursor
    // ("100"), not the mutated cursor ("110") page 1's applyHistory advanced
    // the store to.
    #expect(thisPassCalls[1] == HistoryCall(startHistoryID: "100", pageToken: "p2"))

    // Per-page cursor commit still works: the store ends up on page 2's
    // historyId, not the fixed `start`.
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 120)
}

@Test func hydrationGet404IsSkippedNotTreatedAsExpiry() async throws {
    // A message can vanish between a history event and our follow-up
    // hydration get for an unknown id — a normal race, not a sign the
    // history cursor itself expired. This regression-guards that a 404 from
    // that get (unlike a 404 from listHistory) must not trigger the expiry
    // fallback: it must not reset backfill, nor discard the cursor already
    // committed by this page's applyHistory call.
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistory([historyPage("""
        {"historyId": "130", "history": [
          {"id": "125", "messagesAdded": [{"message":
            {"id": "m1", "threadId": "t1", "historyId": "125",
             "internalDate": "1000", "labelIds": ["INBOX"], "snippet": "sn",
             "payload": {"headers": [{"name": "Subject", "value": "s"}]}}}]},
          {"id": "128", "labelsAdded": [{"message":
            {"id": "mGone", "threadId": "t2", "historyId": "128", "labelIds": ["INBOX"]}}]}
        ]}
        """)])
    // "mGone" is never registered in messagesByID, so ScriptedGmail.getMessage
    // 404s for it, simulating a message deleted before hydration could run.
    let report = try await engine.syncOnce()
    // Both of the page's changes counted as applied — the unknown-id
    // hydration 404 doesn't erase that.
    #expect(report.eventsApplied == 2)
    // m1's add landed; mGone was never materialized (no row to hydrate it
    // into), but that's expected — it must not abort the other change.
    #expect(try await database.recentMessages(account: "x", limit: 5).map(\.id) == ["m1"])
    let account = try #require(try await database.primaryAccount())
    // Cursor advanced to this page's own historyId — NOT reset to a fresh
    // profile cursor, which is what the (mis-triggered) expiry fallback would do.
    #expect(account.historyCursor == 130)
    // Backfill state untouched: the expiry fallback never fired.
    #expect(account.backfillState == "complete")
}
