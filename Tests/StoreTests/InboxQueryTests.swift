import Foundation
import GRDB
import Testing
@testable import Store

private func snap(
    _ id: String, thread: String, date: Int64, labels: [String] = ["INBOX"], subject: String = "s"
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: "ada@x.com", toLine: "you@x.com", subject: subject, snippet: "sn", labelIDs: labels)
}

// MARK: - RED: newest-first, thread_rollup ONLY (in_inbox filter)

@Test func inboxThreadsOrdersNewestFirst() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m2", thread: "t2", date: 300), account: "x")
    _ = try await db.applySnapshot(snap("m3", thread: "t3", date: 200), account: "x")
    let rows = try await db.inboxThreads(account: "x", split: nil, limit: 10)
    #expect(rows.map(\.threadID) == ["t2", "t3", "t1"])
}

@Test func inboxThreadsOnlyReturnsThreadsCurrentlyInInbox() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100, labels: ["INBOX"]), account: "x")
    _ = try await db.applySnapshot(snap("m2", thread: "t2", date: 200, labels: ["ARCHIVED"]), account: "x")
    let rows = try await db.inboxThreads(account: "x", split: nil, limit: 10)
    #expect(rows.map(\.threadID) == ["t1"])
}

// MARK: - RED: split filter

@Test func inboxThreadsFiltersBySplitKeyWhenGiven() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m2", thread: "t2", date: 200), account: "x")
    try await db.writer.write { conn in
        try conn.execute(sql: "UPDATE thread_rollup SET split_key = 'newsletters' WHERE thread_id = 't2'")
    }
    let filtered = try await db.inboxThreads(account: "x", split: "newsletters", limit: 10)
    #expect(filtered.map(\.threadID) == ["t2"])

    let unfiltered = try await db.inboxThreads(account: "x", split: nil, limit: 10)
    #expect(unfiltered.count == 2)  // nil split == every split
}

// MARK: - RED: M3<->M4 seam — enqueueMutation makes the archive visible instantly

@Test func archivingTheOnlyMessageInAThreadDropsItFromTheInboxInstantly() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).map(\.threadID) == ["t1"])

    // Optimistic archive — no server round trip, no history event applied yet.
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)

    let rows = try await db.inboxThreads(account: "x", split: nil, limit: 10)
    #expect(rows.isEmpty)  // instantly gone, before any sync
}

@Test func droppingAFailedArchiveMutationRestoresTheThreadToTheInbox() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).isEmpty)

    // Terminal failure — the flusher gives up on the send and drops it.
    let mutationID = try #require(try await db.pendingMutations(account: "x").first).id
    try await db.dropMutation(id: mutationID, account: "x")

    let rows = try await db.inboxThreads(account: "x", split: nil, limit: 10)
    #expect(rows.map(\.threadID) == ["t1"])  // reverted to canonical: still in the inbox
}

@Test func retiringAMutationRecomputesTheThreadEvenWithoutASeparateLabelsEvent() async throws {
    // Isolates retire's OWN recompute call (the M3<->M4 seam), independent
    // of the `.labels` history branch's recompute (which already existed
    // before this task) — mirrors `MutationRetirementTests`' own pattern of
    // advancing `history_cursor` directly via SQL rather than through a
    // real `.labels` event, so canonical `message_labels` is untouched
    // here. If `retireConfirmedMutations` did NOT call
    // `recomputeThreadFlags` itself, this thread would stay stuck out of
    // the inbox forever (stuck at the enqueue-time recompute's answer)
    // even though canonical still has INBOX and the overlay row is gone.
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).isEmpty)

    let pending = try await db.claimPendingBatch(account: "x", limit: 10)
    try await db.markInFlight(mutationIDs: pending.map(\.id), expectedHistoryID: 150, account: "x")
    try await db.writer.write { try $0.execute(
        sql: "UPDATE accounts SET history_cursor = 150 WHERE email = 'x'") }

    #expect(try await db.retireConfirmedMutations(account: "x") == 1)

    let rows = try await db.inboxThreads(account: "x", split: nil, limit: 10)
    #expect(rows.map(\.threadID) == ["t1"])
}

// MARK: - RED: keyset pagination

@Test func inboxThreadsPaginatesViaKeyset() async throws {
    let db = try HudsonDatabase.inMemory()
    for i in 1...5 {
        _ = try await db.applySnapshot(snap("m\(i)", thread: "t\(i)", date: Int64(i * 10)), account: "x")
    }
    let page1 = try await db.inboxThreads(account: "x", split: nil, limit: 2)
    #expect(page1.map(\.threadID) == ["t5", "t4"])

    let page2 = try await db.inboxThreads(
        account: "x", split: nil, limit: 2,
        before: (page1.last!.lastMessageAt, page1.last!.threadID))
    #expect(page2.map(\.threadID) == ["t3", "t2"])

    let page3 = try await db.inboxThreads(
        account: "x", split: nil, limit: 2,
        before: (page2.last!.lastMessageAt, page2.last!.threadID))
    #expect(page3.map(\.threadID) == ["t1"])

    let page4 = try await db.inboxThreads(
        account: "x", split: nil, limit: 2,
        before: (page3.last!.lastMessageAt, page3.last!.threadID))
    #expect(page4.isEmpty)  // no more pages
}

@Test func inboxThreadsKeysetTieBreaksOnThreadIDWhenLastMessageAtTies() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "tA", date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m2", thread: "tB", date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m3", thread: "tC", date: 100), account: "x")
    let page1 = try await db.inboxThreads(account: "x", split: nil, limit: 2)
    #expect(page1.map(\.threadID) == ["tC", "tB"])  // thread_id DESC tie-break

    let page2 = try await db.inboxThreads(
        account: "x", split: nil, limit: 2,
        before: (page1.last!.lastMessageAt, page1.last!.threadID))
    #expect(page2.map(\.threadID) == ["tA"])
}

// MARK: - RED: rollup-only fields surface correctly, incl. has_attachment

@Test func inboxThreadsSurfacesAllRollupFields() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", thread: "t1", date: 100, labels: ["INBOX", "UNREAD"], subject: "Hello"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: Sanitizer.sanitize(html: nil, plainText: "hi"),
        attachments: [AttachmentMeta(id: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 10)])
    let row = try #require(try await db.inboxThreads(account: "x", split: nil, limit: 10).first)
    #expect(row.threadID == "t1")
    #expect(row.lastMessageID == "m1")
    #expect(row.subject == "Hello")
    #expect(row.snippet == "sn")
    #expect(row.splitKey == "primary")     // Task 7 not yet run — default
    #expect(row.category == "")
    #expect(row.messageCount == 1)
    #expect(row.unread == true)
    #expect(row.inInbox == true)
    #expect(row.hasAttachment == true)
}

@Test func hasAttachmentResetsWhenANewUnhydratedMessageBecomesTheThreadsNewest() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: Sanitizer.sanitize(html: nil, plainText: "hi"),
        attachments: [AttachmentMeta(id: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 10)])
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).first?.hasAttachment == true)

    // A newer message lands in the same thread but hasn't been hydrated yet
    // — has_attachment mirrors "the last message", so it must fall back to
    // unknown (false), not keep leaking the old newest's flag.
    _ = try await db.applySnapshot(snap("m2", thread: "t1", date: 200), account: "x")
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).first?.hasAttachment == false)
}

@Test func reapplyingTheSameHydratedNewestMessageAsAnUpdatePreservesHasAttachment() async throws {
    // Regression for review fix round 1's Critical: `maintainRollup`'s
    // `has_attachment` CASE originally fired on ANY tied-or-newer snapshot
    // (the same unguarded check `subject`/`snippet` safely use, since
    // those ARE snapshot-stable). But `maintainRollup` always writes a
    // literal `has_attachment = 0` — a bare `MessageSnapshot` never
    // carries the real value — so re-applying the SAME already-hydrated
    // newest message as an UPDATE (`wasInsert == false`: a routine label
    // change, a duplicate history event, or a stale-historyId resync)
    // ties on the newest-check and silently blew the true `true` back to
    // `false`, PERMANENTLY (no self-heal: `messageIDsNeedingBodies` never
    // re-selects an already-hydrated message). A distinct-id (m1 -> m2)
    // test — see the sibling test above — can't catch this: it has to be
    // the SAME id, re-applied, that ties against itself.
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: Sanitizer.sanitize(html: nil, plainText: "hi"),
        attachments: [AttachmentMeta(id: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 10)])
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).first?.hasAttachment == true)

    // Re-apply the identical snapshot (same id, same date) — a routine
    // label-change/duplicate-event/resync re-apply, wasInsert == false.
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")

    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).first?.hasAttachment == true)
}
