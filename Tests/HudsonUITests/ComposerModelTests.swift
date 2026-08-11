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
/// — the fixture every test below starts from.
@MainActor
private func makeComposer(
    database: HudsonDatabase, account: AccountRecord, transport: FakeSendTransport
) -> ComposerModel {
    let service = SendService(api: transport, database: database, account: account.email)
    return ComposerModel(database: database, account: account, makeService: { service })
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
