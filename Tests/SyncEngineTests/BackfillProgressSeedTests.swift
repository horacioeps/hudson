import Foundation
import GmailKit
import Store
import Testing
@testable import SyncEngine

private func makeWorld(
    pages: [MessageListPage], messages: [String: GmailMessage],
    consentedAt: Date = .now
) async throws -> (ScriptedGmail, HudsonDatabase, SyncEngine) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: consentedAt)
    let gmail = ScriptedGmail(listPages: pages, messagesByID: messages)
    let engine = SyncEngine(api: gmail, database: database, account: "x")
    return (gmail, database, engine)
}

// MARK: - The window boundary is shared

/// The pin that stops the progress numerator and denominator describing
/// different sets. `backfillQuery` turns this instant into Gmail's `after:`
/// filter and the progress observation counts stored messages from the same
/// instant; two independent expressions of "90 days before consent" would drift
/// and the bar would never reach its denominator.
@Test func theWindowBoundaryMatchesTheGmailFilterItProduces() async throws {
    let consentedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let (gmail, _, engine) = try await makeWorld(
        pages: [MessageListPage(messages: [], nextPageToken: nil, resultSizeEstimate: 0)],
        messages: [:], consentedAt: consentedAt)

    _ = try await engine.syncOnce()

    let query = try #require(await gmail.listQueries.first ?? nil)
    let millis = SyncEngine.backfillWindowStartMilliseconds(
        consentedAt: consentedAt, lookbackDays: 90)
    #expect(query == "after:\(millis / 1_000)")
}

/// A disabled window lists the whole mailbox, so the matching count must be
/// unbounded too — otherwise the denominator would cover everything while the
/// numerator counted only a slice.
@Test func aDisabledWindowCountsFromTheEpoch() {
    #expect(
        SyncEngine.backfillWindowStartMilliseconds(consentedAt: .now, lookbackDays: 0) == 0)
}

// MARK: - Seeding the denominator

/// `resultSizeEstimate` was decoded but thrown away before this. It is the only
/// number Gmail gives us that is scoped to the SAME windowed listing the run
/// performs, which is what makes it the honest denominator.
@Test func theFirstPagesEstimateBecomesTheDenominator() async throws {
    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 1_240)
    let (_, database, engine) = try await makeWorld(
        pages: [page], messages: ["m1": testMessage(id: "m1", historyID: "90")])

    _ = try await engine.syncOnce()

    let account = try #require(try await database.primaryAccount())
    #expect(account.backfillTotalEstimate == 1_240)
    #expect(account.backfillCountBaseline == 0)
}

/// Gmail returns a slightly different estimate on later pages of one listing.
/// Letting a later page move the denominator would make the bar jump backwards
/// mid-download, so only the first page of a run seeds it.
@Test func aLaterPagesEstimateDoesNotMoveTheDenominator() async throws {
    let page1 = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: "p2",
        resultSizeEstimate: 1_240)
    let page2 = MessageListPage(
        messages: [MessageRef(id: "m2", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 77)
    let (_, database, engine) = try await makeWorld(
        pages: [page1, page2],
        messages: [
            "m1": testMessage(id: "m1", historyID: "90"),
            "m2": testMessage(id: "m2", historyID: "91"),
        ])

    _ = try await engine.syncOnce(maxBackfillPages: 1)
    _ = try await engine.syncOnce(maxBackfillPages: 1)

    let account = try #require(try await database.primaryAccount())
    #expect(account.backfillTotalEstimate == 1_240)
}

/// Gmail may omit the field entirely. "Unknown" has to survive as `nil` rather
/// than becoming a zero the UI would then divide by.
@Test func aMissingEstimateLeavesTheDenominatorUnknown() async throws {
    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: nil)
    let (_, database, engine) = try await makeWorld(
        pages: [page], messages: ["m1": testMessage(id: "m1", historyID: "90")])

    _ = try await engine.syncOnce()

    let account = try #require(try await database.primaryAccount())
    #expect(account.backfillTotalEstimate == nil)
}

// MARK: - Cursor expiry restarts the run cleanly

/// **The blocker both reviewers found, at its source.** A §4.3 expiry restarts
/// backfill but deletes no mail, so the previous run's seeds must not carry
/// into the new one — otherwise the fresh listing is measured against a count
/// that already includes everything it is about to re-list, and the bar opens
/// at its ceiling and sits there.
@Test func cursorExpiryClearsTheProgressSeedsSoTheNextRunReSeeds() async throws {
    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 1_240)
    let (gmail, database, engine) = try await makeWorld(
        pages: [page], messages: ["m1": testMessage(id: "m1", historyID: "90")])

    _ = try await engine.syncOnce()
    #expect(try await database.primaryAccount()?.backfillTotalEstimate == 1_240)

    // Next poll: the stored cursor has expired.
    await gmail.setHistoryError(GmailError.invalidRequest(status: 404, message: "expired"))
    _ = try await engine.syncOnce()

    let account = try #require(try await database.primaryAccount())
    #expect(account.backfillState == "pending")
    #expect(account.backfillTotalEstimate == nil)
    #expect(account.backfillCountBaseline == nil)
}

/// After that reset, the next run records a NON-ZERO baseline, because the mail
/// it is about to re-list is already on disk. That is the signal the UI uses to
/// show the quiet status line instead of a bar pinned at 95%.
@Test func aReListRecordsANonZeroBaseline() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    // Mail already on disk from a previous run, inside the window.
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    try await database.writer.write { db in
        for id in ["a", "b", "c"] {
            try db.execute(
                sql: """
                    INSERT INTO messages
                        (account_email, id, thread_id, history_id, internal_date)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: ["x", id, "t", 1, now])
        }
    }
    let page = MessageListPage(
        messages: [], nextPageToken: nil, resultSizeEstimate: 3)
    let gmail = ScriptedGmail(listPages: [page], messagesByID: [:])
    let engine = SyncEngine(api: gmail, database: database, account: "x")

    _ = try await engine.syncOnce()

    let account = try #require(try await database.primaryAccount())
    #expect(account.backfillCountBaseline == 3)
    #expect(account.backfillTotalEstimate == 3)
}
