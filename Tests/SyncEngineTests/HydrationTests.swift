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
