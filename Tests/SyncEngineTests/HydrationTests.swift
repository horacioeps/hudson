import Foundation
import GmailKit
import Store
import Testing
@testable import SyncEngine

@Test func hydratesBodyForMessageWithinPrefetchWindowThenSkipsOnRerun() async throws {
    // A fixed `now` makes the 90-day prefetch window deterministic: every
    // `testMessage`/`testMessageWithBody` in the rest of the suite uses
    // internalDate "1000" (1970), which is always outside the window — this
    // is the only place the hydration path (full-format getMessage,
    // extractContent, Sanitizer.sanitize, saveBody, window filter) runs.
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let threeDaysAgoMS = Int64((fixedNow.timeIntervalSince1970 - 3 * 86_400) * 1_000)

    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)

    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 1)
    let message = testMessageWithBody(
        id: "m1", historyID: "90", internalDate: String(threeDaysAgoMS),
        plainText: "hello hydrated body")
    let gmail = ScriptedGmail(listPages: [page], messagesByID: ["m1": message])
    let engine = SyncEngine(api: gmail, database: database, account: "x", now: { fixedNow })

    let first = try await engine.syncOnce()
    #expect(first.backfilledThisPass == 1)
    #expect(first.bodiesHydrated == 1)

    let stored = try #require(try await database.message(id: "m1", account: "x"))
    #expect(stored.plainText == "hello hydrated body")
    #expect(stored.row.hasBody)

    // Re-running must not re-hydrate an already-current body.
    let second = try await engine.syncOnce()
    #expect(second.bodiesHydrated == 0)
}

// M5 Task 5 review fix: the metadata-fetch path (`SnapshotMapping`, wired
// into backfill/history) is NOT the only writer of
// `rfc822_message_id`/`references_header` — `hydrateBodies` must ALSO
// persist them, since it's the path spec §7.1's "at hydrate time" language
// actually describes, and the metadata path never re-runs for an account
// whose backfill already completed before this migration shipped.
@Test func hydrateBodiesBackfillsThreadingHeadersForAnAlreadyBackfilledMessage() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let threeDaysAgoMS = Int64((fixedNow.timeIntervalSince1970 - 3 * 86_400) * 1_000)

    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    // Simulates the pre-existing-user case: a message row inserted straight
    // through `applySnapshot` (bypassing `SnapshotMapping`/the network
    // entirely) with both threading columns NULL and no body yet — exactly
    // what an account that finished backfill before this migration shipped
    // looks like. Backfill is marked complete so `syncOnce` won't re-list.
    _ = try await database.applySnapshot(
        MessageSnapshot(
            id: "m1", threadID: "t1", historyID: 90, internalDate: threeDaysAgoMS,
            fromLine: "a@ex.com", toLine: "b@ex.com", subject: "s", snippet: "sn",
            labelIDs: ["INBOX"]),
        account: "x")
    try await database.updateBackfill(email: "x", state: "complete", pageToken: nil, addedCount: 0)

    let beforeHydration = try #require(try await database.message(id: "m1", account: "x")).row
    #expect(beforeHydration.rfc822MessageID == nil)
    #expect(beforeHydration.referencesHeader == nil)
    #expect(!beforeHydration.hasBody)

    // The user later opens/hydrates the message: `format: "full"` DOES
    // carry the headers — exactly what a real Gmail response looks like.
    let gmail = ScriptedGmail(messagesByID: [
        "m1": testMessageWithBody(
            id: "m1", historyID: "90", internalDate: String(threeDaysAgoMS),
            plainText: "hello hydrated body",
            messageID: "<m1@mail.example.com>", references: "<root@mail.example.com>")
    ])
    let engine = SyncEngine(api: gmail, database: database, account: "x", now: { fixedNow })

    let report = try await engine.syncOnce()
    #expect(report.bodiesHydrated == 1)

    let afterHydration = try #require(try await database.message(id: "m1", account: "x")).row
    #expect(afterHydration.rfc822MessageID == "<m1@mail.example.com>")
    #expect(afterHydration.referencesHeader == "<root@mail.example.com>")
    #expect(afterHydration.hasBody)
}

@Test func hydration404TombstonesVanishedMessageAndStillHydratesTheOther() async throws {
    // A message can vanish between the history poll that materialized its row
    // (has_body=0) and the follow-up hydration `getMessage(format: "full")` —
    // e.g. a ghost row left by the §4.3 expiry re-list. Regression: that 404
    // must remove the row (so it leaves messageIDsNeedingBodies' work-list
    // instead of 404ing on every future `hudson sync`), must not abort the
    // OTHER in-window message's hydration, and must not be re-fetched on a
    // later pass.
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let threeDaysAgoMS = Int64((fixedNow.timeIntervalSince1970 - 3 * 86_400) * 1_000)

    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail()
    let engine = SyncEngine(api: gmail, database: database, account: "x", now: { fixedNow })

    // Establish the cursor and complete the (empty) backfill first.
    _ = try await engine.syncOnce()

    // Materialize two in-window messages via history — this is data straight
    // out of the history record, no getMessage call involved (mirrors
    // HistoryTests' unknownLabelEventHydratesTheMessage setup).
    await gmail.setHistory([historyPage("""
        {"historyId": "150", "history": [
          {"id": "140", "messagesAdded": [{"message":
            {"id": "mGone", "threadId": "t1", "historyId": "140",
             "internalDate": "\(threeDaysAgoMS)", "labelIds": ["INBOX"], "snippet": "sn",
             "payload": {"headers": [{"name": "Subject", "value": "gone"}]}}}]},
          {"id": "145", "messagesAdded": [{"message":
            {"id": "mSurvivor", "threadId": "t2", "historyId": "145",
             "internalDate": "\(threeDaysAgoMS)", "labelIds": ["INBOX"], "snippet": "sn2",
             "payload": {"headers": [{"name": "Subject", "value": "survivor"}]}}}]}
        ]}
        """)])
    await gmail.setMessages([
        "mSurvivor": testMessageWithBody(
            id: "mSurvivor", historyID: "999", internalDate: String(threeDaysAgoMS),
            plainText: "still here after the vanish")
    ])
    // "mGone" is deliberately never registered in messagesByID: its hydration
    // getMessage(format: "full") 404s, simulating a message deleted between
    // the history poll and body hydration.

    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 2)
    // The OTHER in-window message still hydrated — one bad id didn't stall it.
    #expect(report.bodiesHydrated == 1)

    // mGone was tombstoned and removed, not left stuck at has_body=0.
    #expect(try await database.message(id: "mGone", account: "x") == nil)
    let survivor = try #require(try await database.message(id: "mSurvivor", account: "x"))
    #expect(survivor.plainText == "still here after the vanish")
    #expect(survivor.row.hasBody)

    // A second pass must not re-fetch the vanished id: it's gone from the
    // store, so messageIDsNeedingBodies never lists it again.
    _ = try await engine.syncOnce()
    let calls = await gmail.calls
    #expect(calls.filter { $0 == "get:mGone:full" }.count == 1)
}
