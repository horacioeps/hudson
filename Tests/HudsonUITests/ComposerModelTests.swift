import Foundation
import GmailKit
import Outbox
import Store
import Testing
@testable import HudsonUI

/// A scriptable `SendTransport` double so `ComposerModel`'s tests drive a
/// REAL `SendService` (its dedup state machine, the actual `send_jobs` rows)
/// without a network or a Keychain — exactly the seam `ComposerModel`'s
/// injectable `makeService` factory exists for. An `actor` because
/// `SendTransport` is `Sendable` and these calls are `async`; it records how
/// many real sends happened so a test can assert the undo-hold kept the wire
/// untouched.
private actor FakeSendTransport: SendTransport {
    private(set) var sendCount = 0

    func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage {
        sendCount += 1
        return SentMessage(id: "sent-\(sendCount)", threadId: threadID ?? "t", labelIds: ["SENT"])
    }

    func findSentMessageID(rfc822MessageID: String) async throws -> String? { nil }

    func timesSent() -> Int { sendCount }
}

/// Builds a `ComposerModel` whose `makeService` hands back a real
/// `SendService` layered over `transport`, plus the account email both share
/// — the fixture every test below starts from. `undoHoldWindow` defaults to
/// `ComposerModel`'s own default (15s); the undo-window timing tests below
/// override it to a short duration so they can actually observe the
/// auto-expiry/keyed-timer behavior without a real 15s sleep.
@MainActor
private func makeComposer(
    database: HudsonDatabase, account: AccountRecord, transport: FakeSendTransport,
    undoHoldWindow: Duration = .seconds(15)
) -> ComposerModel {
    let service = SendService(api: transport, database: database, account: account.email)
    return ComposerModel(
        database: database, account: account, makeService: { service },
        undoHoldWindow: undoHoldWindow)
}

// MARK: - Send

/// The core of Task 2's send path: filling out a new compose and calling
/// `send()` must land a durable `send_jobs` row (via the real
/// `SendService.enqueue`) AND report its id as `justSentUndoJobID` so the
/// toast/undo window has a handle. Fields clear on success.
@MainActor
@Test func sendEnqueuesAJobAndReportsAnUndoID() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "compose-send-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: account, transport: transport)

    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Lunch?"
    model.bodyText = "Are you free Thursday?"
    await model.send()

    let jobID = try #require(model.justSentUndoJobID)
    let job = try await db.sendJob(id: jobID, account: email)
    #expect(job != nil)  // a real durable row went into `send_jobs`
    #expect(model.banner == nil)
    #expect(model.to.isEmpty && model.subject.isEmpty && model.bodyText.isEmpty)  // fields cleared
}

/// Undo-send within the hold: `undo()` cancels the just-enqueued job through
/// `SendService.cancel` (which only succeeds while still held), so the row is
/// deleted and the wire was never touched.
@MainActor
@Test func undoWithinHoldCancelsTheSend() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "compose-undo-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: account, transport: transport)

    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Lunch?"
    model.bodyText = "Are you free Thursday?"
    await model.send()
    let jobID = try #require(model.justSentUndoJobID)

    await model.undo()

    #expect(try await db.sendJob(id: jobID, account: email) == nil)  // row deleted by cancel
    #expect(model.justSentUndoJobID == nil)
    #expect(await transport.timesSent() == 0)  // undo beat the wire — nothing ever sent
}

// MARK: - Undo-window auto-expiry

/// Once the undo hold elapses on its own — nobody tapped Undo — the model
/// clears its own `justSentUndoJobID` handle (`scheduleUndoExpiry`), so
/// `ComposerView.bottomToast` (a pure function of that property) hides
/// itself without needing any view-local timer. When the hold elapses and the
/// user did NOT undo, the composer also FLUSHES the now-claimable job to Gmail
/// — the fix for "the app said Sent but the mail never left the queue" (the
/// prior behavior left delivery to a periodic flush that wasn't wired).
@MainActor
@Test func justSentUndoJobIDAutoClearsAfterHoldWindowElapses() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "compose-expiry-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let transport = FakeSendTransport()
    let model = makeComposer(
        database: db, account: account, transport: transport, undoHoldWindow: .milliseconds(60))

    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Lunch?"
    model.bodyText = "Are you free Thursday?"
    await model.send()
    let jobID = try #require(model.justSentUndoJobID)

    try await Task.sleep(for: .milliseconds(220))  // well past the 60ms hold

    #expect(model.justSentUndoJobID == nil)  // undo handle auto-cleared, no `undo()` call needed
    let job = try #require(try await db.sendJob(id: jobID, account: email))
    #expect(job.state == .sent)  // the hold elapsed with no undo -> the composer flushed it out
    #expect(await transport.timesSent() == 1)  // and it actually reached (the fake) Gmail
}

/// Regression test for the exact bug this fix-loop closed: a SECOND send
/// from the same reused `ComposerModel`, started while the FIRST job's undo
/// hold is still open, must not have its own (still-valid) undo handle
/// wiped out early when the first job's timer reaches ITS original
/// deadline. Before `scheduleUndoExpiry` re-checked `justSentUndoJobID ==
/// jobID` (keying the clear to the specific job it was scheduled for), an
/// un-cancelled/un-keyed timer would have cleared whatever
/// `justSentUndoJobID` held at that moment — including a newer, still-valid
/// job's handle — hiding a real undo affordance early.
@MainActor
@Test func secondSendsUndoHandleSurvivesTheFirstSendsOriginalDeadline() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "compose-expiry2-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let transport = FakeSendTransport()
    let model = makeComposer(
        database: db, account: account, transport: transport, undoHoldWindow: .milliseconds(150))

    model.startNew()
    model.to = "friend@example.com"
    model.subject = "First"
    model.bodyText = "First message"
    await model.send()
    let firstJobID = try #require(model.justSentUndoJobID)

    try await Task.sleep(for: .milliseconds(50))  // well within the first job's 150ms hold

    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Second"
    model.bodyText = "Second message"
    await model.send()
    let secondJobID = try #require(model.justSentUndoJobID)
    #expect(secondJobID != firstJobID)

    // Past the FIRST job's original deadline (150ms after it was sent, i.e.
    // ~100ms from here) but well before the SECOND job's own deadline
    // (150ms after IT was sent, i.e. ~200ms from here) — this is the exact
    // window the bug would have cleared the handle early in.
    try await Task.sleep(for: .milliseconds(120))
    #expect(model.justSentUndoJobID == secondJobID)  // still valid — not stomped by job 1's timer

    // Now past the second job's own deadline too.
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.justSentUndoJobID == nil)
}

/// No account/no service: `send()` must never crash — it surfaces a
/// "connect an account" banner and enqueues nothing.
@MainActor
@Test func sendWithNoServiceSurfacesConnectBannerAndEnqueuesNothing() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "compose-noservice-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let model = ComposerModel(database: db, account: account, makeService: { nil })

    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Hi"
    model.bodyText = "Body"
    await model.send()

    #expect(model.justSentUndoJobID == nil)
    #expect(model.banner != nil)
}

// MARK: - Reply

/// Reply mode prefills the threading triple's user-visible legs from the
/// thread's NEWEST message (via `ReplyBuilder`/`SubjectNormalization`): the
/// subject collapses to exactly one `Re: `, the recipient is the
/// correspondent (not the replying user), and `mode` carries the thread id.
@MainActor
@Test func startReplyPrefillsSubjectAndRecipientFromThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let account = try #require(try await db.account(email: AppModel.demoAccount))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: account, transport: transport)

    await model.startReply(threadID: "t01")

    #expect(model.subject == "Re: Dinner Friday?")  // collapsed via SubjectNormalization
    #expect(model.to.contains("sofia@brightleaf.example"))  // the correspondent, not "you@hudson.app"
    guard case .reply(let threadID) = model.mode else {
        Issue.record("expected reply mode after startReply")
        return
    }
    #expect(threadID == "t01")
}

/// Sending a reply must carry the thread's id (so Gmail keeps it in-thread)
/// through the real `enqueue` path, and use the body the user actually
/// edited rather than the quoted prefill scaffold.
@MainActor
@Test func sendingAReplyThreadsToTheOriginalThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let account = try #require(try await db.account(email: AppModel.demoAccount))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: account, transport: transport)

    await model.startReply(threadID: "t01")
    model.bodyText = "Sounds perfect, see you at 7."
    await model.send()

    let jobID = try #require(model.justSentUndoJobID)
    let job = try #require(try await db.sendJob(id: jobID, account: AppModel.demoAccount))
    #expect(job.threadID == "t01")  // threaded back to the original Gmail thread
}

// MARK: - Reply quoting (the composer opens clean; the quote rides along)

/// Seeds a thread whose newest message body ALREADY contains a round of
/// quoted history — the shape every real reply chain has after the first
/// exchange, and the one that used to make the composer accumulate `>>`.
private func seedThreadWithPriorHistory(
    into db: HudsonDatabase, account: String
) async throws {
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "q1-m0", threadID: "q1", historyID: 1, internalDate: 1000,
            fromLine: "Dhravya Shah <hi@dhravya.example>", toLine: account,
            subject: "i want to work with you", snippet: "sn", labelIDs: ["INBOX"]),
        account: account)
    try await db.saveBody(
        messageID: "q1-m0", account: account,
        body: Sanitizer.sanitize(
            html: nil,
            plainText: """
                Sounds good, let's find a time.

                On Thu, Aug 6, 2026 at 11:25 PM Mannas <m@example.com> wrote:
                > Hey Dhravya, stepping off for now.
                > Let me know what works
                >
                """),
        attachments: [])
}

@MainActor
@Test func replyOpensWithAnEmptyBodyAndTheQuoteHeldAside() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedThreadWithPriorHistory(into: db, account: account)
    let record = try #require(try await db.account(email: account))
    let model = ComposerModel(database: db, account: record, makeService: { nil })

    await model.startReply(threadID: "q1")

    // The editor is clean — cursor ready, nothing to scroll past.
    #expect(model.bodyText.isEmpty)
    // ...but the quote exists and will be sent.
    #expect(model.quotedReplyText.contains("> Sounds good, let's find a time."))
    #expect(model.quotedReplyText.hasPrefix("On Dhravya Shah"))
}

@MainActor
@Test func theQuoteDoesNotReQuoteHistoryTheOriginalAlreadyCarried() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedThreadWithPriorHistory(into: db, account: account)
    let record = try #require(try await db.account(email: account))
    let model = ComposerModel(database: db, account: record, makeService: { nil })

    await model.startReply(threadID: "q1")

    // The regression: quoting the original WHOLE re-marked text that was
    // already ">"-marked, so each round added a level of nesting and another
    // attribution line.
    #expect(!model.quotedReplyText.contains(">>"))
    #expect(model.quotedReplyText.components(separatedBy: "wrote:").count - 1 == 1)
    #expect(!model.quotedReplyText.contains("stepping off for now"))
}

@MainActor
@Test func theSentBodyIsTheUsersTextAboveTheQuote() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedThreadWithPriorHistory(into: db, account: account)
    let record = try #require(try await db.account(email: account))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: record, transport: transport)

    await model.startReply(threadID: "q1")
    model.bodyText = "Thursday works."

    // Asserted on the exact string handed to `OutboxMessage` rather than on
    // the built MIME, whose parts are base64 (see `MimeBuilder`) — the
    // encoding itself is covered by Outbox's golden tests; what matters here
    // is that holding the quote outside `bodyText` doesn't drop it, and that
    // it lands BELOW the reply.
    let sent = model.outgoingBody
    let reply = try #require(sent.range(of: "Thursday works."))
    let quote = try #require(sent.range(of: "> Sounds good, let's find a time."))
    #expect(reply.lowerBound < quote.lowerBound)

    // ...and the send still threads, with the quote attached.
    await model.send()
    let jobID = try #require(model.justSentUndoJobID)
    let job = try #require(try await db.sendJob(id: jobID, account: account))
    #expect(job.threadID == "q1")
}

@MainActor
@Test func aNewComposeCarriesNoQuoteAndSendsExactlyWhatWasTyped() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let account = try #require(try await db.account(email: AppModel.demoAccount))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: account, transport: transport)

    // A reply first, so a stale quote would have something to leak from.
    await model.startReply(threadID: "t01")
    model.startNew()

    #expect(model.quotedReplyText.isEmpty)
    model.to = "a@example.com"
    model.subject = "Hello"
    model.bodyText = "Just this."
    // Checked BEFORE sending — `send()` clears the draft on success.
    // Nothing from the earlier reply leaked into the new draft.
    #expect(model.outgoingBody == "Just this.")

    await model.send()
    let jobID = try #require(model.justSentUndoJobID)
    #expect(try await db.sendJob(id: jobID, account: AppModel.demoAccount) != nil)
}

// MARK: - Send-as identity on the wire

/// Hudson sent a bare address, so recipients saw "mannasnarang8" where Gmail
/// shows "Mannas". The name is adopted from the account's own SENT mail.
@MainActor
@Test func aSendCarriesTheAccountsEstablishedDisplayName() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "mannas@example.com"
    try await db.upsertAccount(email: account, clientID: "c", consentedAt: .now)
    for i in 1...3 {
        _ = try await db.applySnapshot(
            MessageSnapshot(
                id: "s\(i)", threadID: "ts\(i)", historyID: Int64(i), internalDate: Int64(i),
                fromLine: "Mannas <\(account)>", toLine: "x@example.com",
                subject: "s", snippet: "sn", labelIDs: ["SENT"]),
            account: account)
    }
    let record = try #require(try await db.account(email: account))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: record, transport: transport)

    model.startNew()
    model.to = "someone@example.com"
    model.subject = "Hello"
    model.bodyText = "hi, im mannas"
    await model.send()

    let jobID = try #require(model.justSentUndoJobID)
    let job = try #require(try await db.sendJob(id: jobID, account: account))
    // The From header is plain text in the MIME (only bodies are base64), so
    // this asserts on what actually goes out, not on an intermediate value.
    let mime = String(decoding: job.rawMIME, as: UTF8.self)
    #expect(mime.contains("From: Mannas <\(account)>"))
}

/// A brand-new account has no sent mail to learn from, and must still send.
@MainActor
@Test func aSendWithNoKnownIdentityFallsBackToTheBareAddress() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "fresh@example.com"
    try await db.upsertAccount(email: account, clientID: "c", consentedAt: .now)
    let record = try #require(try await db.account(email: account))
    let transport = FakeSendTransport()
    let model = makeComposer(database: db, account: record, transport: transport)

    model.startNew()
    model.to = "someone@example.com"
    model.subject = "Hello"
    model.bodyText = "hi"
    await model.send()

    let jobID = try #require(model.justSentUndoJobID)
    let job = try #require(try await db.sendJob(id: jobID, account: account))
    let mime = String(decoding: job.rawMIME, as: UTF8.self)
    #expect(mime.contains("From: \(account)"))
}
