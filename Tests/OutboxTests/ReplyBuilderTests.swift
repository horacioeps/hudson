import Foundation
import Store
import Testing
@testable import Outbox

// M5 Task 5: reply threading integration. `replyMessage` is the seam
// between a stored Gmail thread and `SendService.enqueue` — it must
// assemble spec §7.1's FULL threading triple (Gmail `threadId`, RFC
// `In-Reply-To`/`References`, a normalized matching `Re:` Subject) from
// whatever the thread's newest message actually carries, not from
// caller-supplied guesses.

private let account = "me@hudson.test"
private let threadID = "t1"

/// Seeds a two-message thread directly through `applySnapshot` (the real
/// write path — same posture as `Tests/StoreTests/Support/TestSeed.swift`)
/// so `ReplyBuilder` reads exactly what a real sync would have persisted,
/// including the two Task-5 threading columns (`rfc822MessageID`/
/// `referencesHeader`) no earlier milestone populated.
private func seedThread(_ db: HudsonDatabase) async throws {
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    // Oldest message: Alice starts the thread. No References header of its
    // own (it's the root).
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "m1", threadID: threadID, historyID: 1, internalDate: 1_000,
            fromLine: "Alice <alice@example.com>", toLine: "me@hudson.test",
            subject: "Trip planning", snippet: "Let's go to the mountains.",
            labelIDs: ["INBOX"],
            rfc822MessageID: "<m1@mail.example.com>", referencesHeader: nil),
        account: account)
    // Newest message: Bob replies-all, already carrying a normalized
    // Subject and a References chain back to m1 — exactly what a real
    // Gmail thread's second message looks like.
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "m2", threadID: threadID, historyID: 2, internalDate: 2_000,
            fromLine: "Bob <bob@example.com>", toLine: "me@hudson.test, alice@example.com",
            subject: "Re: Trip planning", snippet: "Sounds fun!",
            labelIDs: ["INBOX"],
            rfc822MessageID: "<m2@mail.example.com>", referencesHeader: "<m1@mail.example.com>"),
        account: account)
}

@Test func replyThreadsAgainstNewestMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedThread(db)

    let reply = try await replyMessage(
        to: threadID, account: account, database: db, from: "me@hudson.test",
        bodyText: "Sounds good!", bodyHTML: nil, replyAll: false)

    // Leg 1: Gmail's own thread id.
    #expect(reply.threadID == threadID)
    // Leg 2: In-Reply-To is the IMMEDIATE parent's Message-ID (m2, the
    // newest message, not m1).
    #expect(reply.inReplyTo == "<m2@mail.example.com>")
    // References is the ACCUMULATED chain: m2's own References (just m1)
    // PLUS m2's own Message-ID appended — so a third reply in this chain
    // would still reference the whole thread, not just its immediate parent.
    #expect(reply.references == ["<m1@mail.example.com>", "<m2@mail.example.com>"])
    // Leg 3: a normalized Subject that matches — m2's Subject already has
    // one "Re: ", so normalization must not double it.
    #expect(reply.subject == "Re: Trip planning")
    // Plain reply (not reply-all): only the newest message's sender.
    #expect(reply.to == ["bob@example.com"])
    #expect(reply.cc == [])
    #expect(reply.bodyText == "Sounds good!")
    #expect(reply.from == "me@hudson.test")
}

@Test func replyAllIncludesOtherOriginalRecipientsButNotSelf() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedThread(db)

    let reply = try await replyMessage(
        to: threadID, account: account, database: db, from: "me@hudson.test",
        bodyText: "Count me in.", bodyHTML: nil, replyAll: true)

    // Sender first, then the newest message's other To recipients (Alice),
    // with the reply's own From address (me@hudson.test) excluded even
    // though it was on the original To line.
    #expect(reply.to == ["bob@example.com", "alice@example.com"])
}

@Test func replySubjectNormalizesAnUnprefixedOriginal() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "solo", threadID: "t2", historyID: 1, internalDate: 1_000,
            fromLine: "Alice <alice@example.com>", toLine: "me@hudson.test",
            subject: "No prefix yet", snippet: "first message",
            labelIDs: ["INBOX"],
            rfc822MessageID: "<solo@mail.example.com>", referencesHeader: nil),
        account: account)

    let reply = try await replyMessage(
        to: "t2", account: account, database: db, from: "me@hudson.test",
        bodyText: "Reply body", bodyHTML: nil, replyAll: false)

    #expect(reply.subject == "Re: No prefix yet")
    #expect(reply.inReplyTo == "<solo@mail.example.com>")
    // The root message has no References of its own, so the reply's chain
    // is just the root's own Message-ID.
    #expect(reply.references == ["<solo@mail.example.com>"])
}

@Test func replyToEmptyOrUnknownThreadThrows() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)

    await #expect(throws: ReplyBuilderError.self) {
        _ = try await replyMessage(
            to: "no-such-thread", account: account, database: db, from: "me@hudson.test",
            bodyText: "Body", bodyHTML: nil, replyAll: false)
    }
}
