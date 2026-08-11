import Foundation
import GRDB
import Testing
@testable import Store

// M5 Task 1: `send_jobs` durable queue — the send-side twin of
// `MutationQueueMigrationTests`/`MutationRetirementTests`. Exercises the
// state machine (`pending`/`held` → `in_flight` → `sent`/`failed`) and the
// two invariants spec §7.3 hangs the dedup protocol on: (1) the
// `in_flight` transition is a real, independently-committed write callers
// can perform BEFORE the network call, and (2) the same RFC 822
// `Message-ID` can never be enqueued twice for one account.

@Test func v7CreatesSendJobsTable() throws {
    let database = try HudsonDatabase.inMemory()
    let columns = try database.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(send_jobs)").map { $0["name"] as String }
    }
    for expected in ["id", "account_email", "rfc822_message_id", "thread_id", "raw_mime",
                     "state", "hold_until", "enqueued_at", "sent_message_id"] {
        #expect(columns.contains(expected), "missing column \(expected)")
    }
}

@Test func enqueueSendInsertsPendingAndIsReadableBackViaClaim() async throws {
    let database = try HudsonDatabase.inMemory()
    let id = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<m1@hudson.local>", threadID: "t1",
        rawMIME: Data("raw-mime-bytes".utf8), holdUntil: 1_100, now: 1_000)
    #expect(id > 0)

    let jobs = try await database.claimSendable(account: "a@b.c", now: 2_000)
    #expect(jobs.count == 1)
    #expect(jobs[0].id == id)
    #expect(jobs[0].state == .pending)
    #expect(jobs[0].account == "a@b.c")
    #expect(jobs[0].rfc822MessageID == "<m1@hudson.local>")
    #expect(jobs[0].threadID == "t1")
    #expect(jobs[0].rawMIME == Data("raw-mime-bytes".utf8))
    #expect(jobs[0].holdUntil == 1_100)
    #expect(jobs[0].enqueuedAt == 1_000)
    #expect(jobs[0].sentMessageID == nil)
}

@Test func claimSendableExcludesJobsStillWithinTheirUndoHold() async throws {
    let database = try HudsonDatabase.inMemory()
    _ = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<held@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 5_000, now: 1_000)
    // now (2000) is still before hold_until (5000) — the undo-send window
    // hasn't elapsed, so the flusher must not see this job yet.
    let jobs = try await database.claimSendable(account: "a@b.c", now: 2_000)
    #expect(jobs.isEmpty)
    // Once past the hold, it becomes claimable.
    let afterHold = try await database.claimSendable(account: "a@b.c", now: 5_000)
    #expect(afterHold.count == 1)
}

@Test func claimSendableReturnsOldestFirst() async throws {
    let database = try HudsonDatabase.inMemory()
    let first = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<first@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 100, now: 100)
    let second = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<second@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 100, now: 200)
    let jobs = try await database.claimSendable(account: "a@b.c", now: 1_000)
    #expect(jobs.map(\.id) == [first, second])
}

@Test func markSendInFlightTransitionsAndRemovesFromClaimable() async throws {
    let database = try HudsonDatabase.inMemory()
    let id = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<m1@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 0, now: 0)

    try await database.markSendInFlight(id: id, account: "a@b.c")

    let claimable = try await database.claimSendable(account: "a@b.c", now: 1_000)
    #expect(claimable.isEmpty)
    let inFlight = try await database.inFlightSendJobs(account: "a@b.c")
    #expect(inFlight.count == 1)
    #expect(inFlight[0].id == id)
    #expect(inFlight[0].state == .inFlight)
}

@Test func markSentRecordsGmailMessageIDAndClearsInFlight() async throws {
    let database = try HudsonDatabase.inMemory()
    let id = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<m1@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 0, now: 0)
    try await database.markSendInFlight(id: id, account: "a@b.c")

    try await database.markSent(id: id, account: "a@b.c", sentMessageID: "gmail-sent-1")

    let inFlight = try await database.inFlightSendJobs(account: "a@b.c")
    #expect(inFlight.isEmpty)
    let row = try database.writer.read { db in
        try Row.fetchOne(db, sql: "SELECT state, sent_message_id FROM send_jobs WHERE id = ?", arguments: [id])
    }
    #expect(row?["state"] == "sent")
    #expect(row?["sent_message_id"] == "gmail-sent-1")
}

@Test func markSendFailedIsTerminalAndRemovesFromClaimableAndInFlight() async throws {
    let database = try HudsonDatabase.inMemory()
    let id = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<m1@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 0, now: 0)
    try await database.markSendInFlight(id: id, account: "a@b.c")

    try await database.markSendFailed(id: id, account: "a@b.c")

    #expect(try await database.inFlightSendJobs(account: "a@b.c").isEmpty)
    #expect(try await database.claimSendable(account: "a@b.c", now: 1_000).isEmpty)
}

@Test func cancelSendDeletesTheJobWhileStillWithinTheHoldWindow() async throws {
    let database = try HudsonDatabase.inMemory()
    let id = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<m1@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 5_000, now: 1_000)

    let cancelled = try await database.cancelSend(id: id, account: "a@b.c", now: 2_000)

    #expect(cancelled)
    #expect(try await database.claimSendable(account: "a@b.c", now: 10_000).isEmpty)
}

@Test func cancelSendRefusesOnceTheHoldHasElapsed() async throws {
    let database = try HudsonDatabase.inMemory()
    let id = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<m1@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 1_000, now: 500)

    // now has reached hold_until — the undo window is over even though the
    // flusher may not have claimed it yet; undo must not resurrect after this.
    let cancelled = try await database.cancelSend(id: id, account: "a@b.c", now: 1_000)

    #expect(!cancelled)
    #expect(try await database.claimSendable(account: "a@b.c", now: 1_000).count == 1)
}

@Test func cancelSendRefusesOnceTheJobIsInFlight() async throws {
    let database = try HudsonDatabase.inMemory()
    let id = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<m1@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 0, now: 0)
    try await database.markSendInFlight(id: id, account: "a@b.c")

    // Can't be recalled once the network send may already be in flight —
    // the state machine has moved past the point undo is offered.
    let cancelled = try await database.cancelSend(id: id, account: "a@b.c", now: 1_000)

    #expect(!cancelled)
    #expect(try await database.inFlightSendJobs(account: "a@b.c").count == 1)
}

@Test func enqueueSendRejectsADuplicateRFC822MessageIDForTheSameAccount() async throws {
    let database = try HudsonDatabase.inMemory()
    _ = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<dup@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 0, now: 0)

    // The UNIQUE (account_email, rfc822_message_id) index is the
    // database-layer half of the dedup guard (§7.3) — a second enqueue of
    // the same Message-ID must fail loudly, not silently double-queue.
    await #expect(throws: DatabaseError.self) {
        try await database.enqueueSend(
            account: "a@b.c", rfc822MessageID: "<dup@hudson.local>", threadID: nil,
            rawMIME: Data(), holdUntil: 0, now: 0)
    }
}

@Test func enqueueSendAllowsTheSameRFC822MessageIDAcrossDifferentAccounts() async throws {
    let database = try HudsonDatabase.inMemory()
    _ = try await database.enqueueSend(
        account: "a@b.c", rfc822MessageID: "<shared@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 0, now: 0)
    let secondID = try await database.enqueueSend(
        account: "x@y.z", rfc822MessageID: "<shared@hudson.local>", threadID: nil,
        rawMIME: Data(), holdUntil: 0, now: 0)
    #expect(secondID > 0)
}
