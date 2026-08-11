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
