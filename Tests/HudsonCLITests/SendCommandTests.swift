import Foundation
import GmailKit
import Outbox
import Store
import Testing

@testable import HudsonCLI

// M5 Task 6: `hudson send` + `hudson reply` CLI wiring. `Runtime.bootstrap()`
// needs real Keychain credentials, so the network-dependent half of these
// commands (`SendCLI.enqueueFlushAndReport`) isn't exercised here — that
// path is already covered end-to-end by `Tests/OutboxTests/SendServiceTests`
// against a scripted transport. What IS directly testable without a
// Keychain, per the plan's "arg parsing / dry-run enqueue against a temp
// DB": (1) ArgumentParser parses each command's flags correctly and rejects
// missing required ones, and (2) the enqueue half of the send path — build
// an `OutboxMessage`, hand it to `SendService.enqueue` — produces a real,
// readable-back row in a temp/in-memory `HudsonDatabase`, with no network
// or Keychain involved.

/// A no-op `SendTransport` double — the dry-run enqueue tests below only
/// exercise `enqueue` (a pure Store write), never `flushOnce`, so nothing
/// here should ever actually be called; each method traps if it is.
struct UnusedSendTransport: SendTransport {
    func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage {
        Issue.record("dry-run enqueue test should never reach the network")
        return SentMessage(id: "unexpected", threadId: "unexpected", labelIds: [])
    }

    func findSentMessageID(rfc822MessageID: String) async throws -> String? {
        Issue.record("dry-run enqueue test should never reach the network")
        return nil
    }
}

/// A `SendTransport` double that actually "sends" — used by the
/// `reportLine`/`flushOnce` interplay tests below, which (unlike the
/// dry-run enqueue tests) need a real flush pass to happen against a temp
/// DB. Every send succeeds with a fresh id; the probe path is never
/// exercised by those tests, so it's a plain miss.
actor AlwaysSucceedsSendTransport: SendTransport {
    private var nextID = 0

    func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage {
        nextID += 1
        return SentMessage(id: "sent-\(nextID)", threadId: threadID ?? "t-\(nextID)", labelIds: ["SENT"])
    }

    func findSentMessageID(rfc822MessageID: String) async throws -> String? { nil }
}

// MARK: - `hudson send` argument parsing

@Test func sendCommandParsesToSubjectBodyAndAttach() throws {
    let command = try SendCommand.parse([
        "--to", "a@example.com", "--subject", "Hi there", "--body", "Hello!",
        "--attach", "/tmp/one.pdf", "--attach", "/tmp/two.png",
    ])
    #expect(command.to == ["a@example.com"])
    #expect(command.subject == "Hi there")
    #expect(command.body == "Hello!")
    #expect(command.attach == ["/tmp/one.pdf", "/tmp/two.png"])
}

@Test func sendCommandAllowsMultipleToAddresses() throws {
    let command = try SendCommand.parse([
        "--to", "a@example.com", "--to", "b@example.com",
        "--subject", "Hi", "--body", "Hello!",
    ])
    #expect(command.to == ["a@example.com", "b@example.com"])
}

@Test func sendCommandRequiresTo() throws {
    #expect(throws: (any Error).self) {
        _ = try SendCommand.parse(["--subject", "Hi", "--body", "Hello!"])
    }
}

@Test func sendCommandRequiresSubject() throws {
    #expect(throws: (any Error).self) {
        _ = try SendCommand.parse(["--to", "a@example.com", "--body", "Hello!"])
    }
}

@Test func sendCommandAttachDefaultsToEmpty() throws {
    let command = try SendCommand.parse(["--to", "a@example.com", "--subject", "Hi", "--body", "Hello!"])
    #expect(command.attach.isEmpty)
}

// MARK: - `hudson reply` argument parsing

@Test func replyCommandParsesThreadIDAllAndBody() throws {
    let command = try ReplyCommand.parse(["t123", "--all", "--body", "Sounds good"])
    #expect(command.threadID == "t123")
    #expect(command.replyAll == true)
    #expect(command.body == "Sounds good")
}

@Test func replyCommandDefaultsAllToFalse() throws {
    let command = try ReplyCommand.parse(["t123", "--body", "Sounds good"])
    #expect(command.replyAll == false)
}

@Test func replyCommandRequiresThreadID() throws {
    #expect(throws: (any Error).self) {
        _ = try ReplyCommand.parse(["--body", "Sounds good"])
    }
}

// MARK: - `SendCLI` helpers (pure, Runtime-independent)

@Test func resolveBodyReturnsExplicitBodyWithoutTouchingStdin() throws {
    // Only the explicit-body branch is safe to exercise in an automated
    // suite — the stdin-fallback branch would block waiting for EOF under
    // an interactive `swift test` run, so it is intentionally left
    // uncovered here (manually verified via `echo hi | hudson send …`).
    let text = try SendCLI.resolveBody("Explicit body text")
    #expect(text == "Explicit body text")
}

@Test func loadAttachmentsReadsFileContentsAndInfersMIMEType() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hudson-send-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("note.txt")
    try Data("attachment body".utf8).write(to: fileURL)

    let attachments = try SendCLI.loadAttachments([fileURL.path])

    #expect(attachments.count == 1)
    #expect(attachments[0].filename == "note.txt")
    #expect(attachments[0].data == Data("attachment body".utf8))
    #expect(attachments[0].mimeType == "text/plain")
}

@Test func loadAttachmentsThrowsOnAMissingFile() throws {
    #expect(throws: (any Error).self) {
        _ = try SendCLI.loadAttachments(["/nonexistent/path/that/should/not/exist.pdf"])
    }
}

// MARK: - Dry-run enqueue against a temp DB (no Runtime/Keychain/network)

@Test func sendDryRunEnqueueBuildsAValidPendingJobInATempDB() async throws {
    let database = try HudsonDatabase.inMemory()
    let account = "me@hudson.test"
    let command = try SendCommand.parse([
        "--to", "you@example.com", "--subject", "Hi", "--body", "Hello there",
    ])
    let message = command.buildMessage(from: account, bodyText: command.body!, attachments: [])
    let service = SendService(api: UnusedSendTransport(), database: database, account: account)

    let jobID = try await service.enqueue(message, now: 1_000)
    let job = try await database.sendJob(id: jobID, account: account)

    #expect(job != nil)
    #expect(job?.state == .pending)
    #expect(job?.threadID == nil)
}

@Test func replyDryRunEnqueueThreadsAgainstTheStoredMessage() async throws {
    let database = try HudsonDatabase.inMemory()
    let account = "me@hudson.test"
    try await database.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await database.applySnapshot(
        MessageSnapshot(
            id: "m1", threadID: "t1", historyID: 1, internalDate: 1_000,
            fromLine: "Alice <alice@example.com>", toLine: account,
            subject: "Trip planning", snippet: "Let's go.", labelIDs: ["INBOX"],
            rfc822MessageID: "<m1@mail.example.com>", referencesHeader: nil),
        account: account)

    let command = try ReplyCommand.parse(["t1", "--body", "Sounds good!"])
    let message = try await replyMessage(
        to: command.threadID, account: account, database: database,
        from: account, bodyText: command.body!, replyAll: command.replyAll)
    let service = SendService(api: UnusedSendTransport(), database: database, account: account)

    let jobID = try await service.enqueue(message, now: 1_000)
    let job = try await database.sendJob(id: jobID, account: account)

    #expect(job != nil)
    #expect(job?.threadID == "t1")
}

// MARK: - `SendCLI.reportLine` — post-flush report (regression: piggybacked
// flush must never silently deliver an earlier held job without saying so,
// and the still-held branch must never claim waiting alone will deliver it)

@Test func reportLineForAHeldJobDoesNotClaimWaitingWillDeliverIt() async throws {
    let database = try HudsonDatabase.inMemory()
    let account = "me@hudson.test"
    let transport = AlwaysSucceedsSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let message = OutboxMessage(
        from: account, to: ["you@example.com"], subject: "Hi", bodyText: "Hello")
    let jobID = try await service.enqueue(message, undoHold: .seconds(15), now: 1_000)
    let job = try await database.sendJob(id: jobID, account: account)

    let line = SendCLI.reportLine(job: job!, jobID: jobID, confirmedThisPass: 0, now: 1_000)

    // The old text falsely implied a background process would eventually
    // deliver a held job on its own — nothing in M5 does.
    #expect(!line.contains("or wait"))
    #expect(line.contains("queued"))
    #expect(line.contains("hudson send"))
    // No other jobs were confirmed, so no side-note should appear.
    #expect(!line.contains("also delivered"))
}

@Test func reportLineSurfacesAnEarlierHeldJobDeliveredAsASideEffectOfThisFlush() async throws {
    // Reproduces the exact scenario the fix targets: an EARLIER `hudson
    // send` left job1 queued past its undo hold (simulated here via
    // `undoHold: .zero`). By the time a SECOND `hudson send` runs — and
    // enqueues job2, still inside ITS OWN fresh 15s undo hold — job2's
    // piggybacked `flushOnce` pass claims and sends job1 as a side effect.
    // The report on job2 must say so; it must not stay silent about job1.
    let database = try HudsonDatabase.inMemory()
    let account = "me@hudson.test"
    let transport = AlwaysSucceedsSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let earlier = OutboxMessage(
        from: account, to: ["a@example.com"], subject: "Earlier", bodyText: "First message")
    let job1 = try await service.enqueue(earlier, undoHold: .zero, now: 1_000)

    let fresh = OutboxMessage(
        from: account, to: ["b@example.com"], subject: "Fresh", bodyText: "Second message")
    let job2 = try await service.enqueue(fresh, undoHold: .seconds(15), now: 1_000)

    let confirmedThisPass = try await service.flushOnce(now: 1_000)
    #expect(confirmedThisPass == 1)  // only job1 was past its hold and claimable

    let job1Row = try await database.sendJob(id: job1, account: account)
    let job2Row = try await database.sendJob(id: job2, account: account)
    #expect(job1Row?.state == .sent)  // job1 really WAS silently sent this pass
    #expect(job2Row?.state == .pending)  // job2 is still within its own hold

    let line = SendCLI.reportLine(
        job: job2Row!, jobID: job2, confirmedThisPass: confirmedThisPass, now: 1_000)

    #expect(line.contains("also delivered 1 other previously-queued message"))
    #expect(!line.contains("or wait"))
    #expect(line.contains("queued"))  // job2 itself is still just queued, not sent
}

@Test func reportLineForASentJobExcludesItselfFromTheOtherCount() async throws {
    // Two jobs both past their hold: `flushOnce` confirms both in one pass.
    // When reporting on job2 — which IS one of the two confirmed sends —
    // the side-note must say "1 other" (job1), not "2 other": job2 must not
    // double-count itself.
    let database = try HudsonDatabase.inMemory()
    let account = "me@hudson.test"
    let transport = AlwaysSucceedsSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let first = OutboxMessage(from: account, to: ["a@example.com"], subject: "First", bodyText: "One")
    let job1 = try await service.enqueue(first, undoHold: .zero, now: 1_000)
    let second = OutboxMessage(from: account, to: ["b@example.com"], subject: "Second", bodyText: "Two")
    let job2 = try await service.enqueue(second, undoHold: .zero, now: 1_000)

    let confirmedThisPass = try await service.flushOnce(now: 1_000)
    #expect(confirmedThisPass == 2)

    let job2Row = try await database.sendJob(id: job2, account: account)
    #expect(job2Row?.state == .sent)

    let line = SendCLI.reportLine(
        job: job2Row!, jobID: job2, confirmedThisPass: confirmedThisPass, now: 1_000)

    #expect(line.hasPrefix("sent"))
    #expect(line.contains("also delivered 1 other previously-queued message"))
    #expect(!line.contains("2 other"))
    _ = job1
}
