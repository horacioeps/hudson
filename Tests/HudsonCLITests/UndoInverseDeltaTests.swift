import Foundation
import Store
import Testing

@testable import HudsonCLI

/// `undo`'s pure logic: flipping op while keeping the label fixed, and the
/// reverse-command guidance offered once a delta has already flushed+retired
/// (post-review fix: `undo` must never hard-fail just because the action
/// already synced — see `UndoCommand`'s doc comment).
@Test func undoInvertsAddToRemove() {
    let delta = UndoCommand.inverseDelta(labelID: "STARRED", op: .add)
    #expect(delta == LabelDelta(labelID: "STARRED", op: .remove))
}

@Test func undoInvertsRemoveToAdd() {
    let delta = UndoCommand.inverseDelta(labelID: "INBOX", op: .remove)
    #expect(delta == LabelDelta(labelID: "INBOX", op: .add))
}

/// (a) A live pending delta exists — `undo`'s inverse, enqueued through the
/// exact same `enqueueMutation` path every triage command uses, cancels it
/// (net no-op: nothing was ever sent, matching `enqueueMutation`'s
/// opposite-op contract from Task 2).
@Test func undoCancelsAStillPendingDelta() async throws {
    let (database, runtime) = try await makeTestRuntime(labelIDs: ["UNREAD"])

    // Simulate `archive`'s enqueue: remove INBOX (message starts without it
    // here, but the queue doesn't require the message to already have the
    // label — it only cares about the live delta itself).
    try await database.enqueueMutation(
        messageID: "msg1", labelID: "INBOX", op: .remove,
        account: runtime.account.email, now: 1)
    var pending = try await database.pendingMutations(account: runtime.account.email)
    let newest = try #require(pending.last(where: { $0.messageID == "msg1" }))
    #expect(newest.op == .remove)

    let inverse = UndoCommand.inverseDelta(labelID: newest.labelID, op: newest.op)
    #expect(inverse == LabelDelta(labelID: "INBOX", op: .add))
    try await database.enqueueMutation(
        messageID: "msg1", labelID: inverse.labelID, op: inverse.op,
        account: runtime.account.email, now: 2)

    pending = try await database.pendingMutations(account: runtime.account.email)
    #expect(pending.isEmpty)
}

/// (b) No live pending delta (the default auto-flush path already sent and
/// retired it) but the message exists locally and is archived — the exit-0
/// "already synced" path: `reportAlreadySynced` must not throw, and its
/// guidance must name `unarchive` as the reverse.
@Test func undoWithNoPendingDeltaOnArchivedMessageSuggestsUnarchiveAndDoesNotFail() async throws {
    let (_, runtime) = try await makeTestRuntime(labelIDs: ["UNREAD"])  // no INBOX => archived

    #expect(UndoCommand.suggestedReversals(labelIDs: ["UNREAD"]) == ["unarchive", "read"])

    do {
        try await UndoCommand.reportAlreadySynced(id: "msg1", runtime: runtime)
    } catch {
        Issue.record("reportAlreadySynced must not throw for an already-synced, still-known message: \(error)")
    }
}

/// A message with none of the three signals (in the inbox, unstarred, read)
/// offers no reversal guess — still must not throw.
@Test func undoSuggestsNothingForAnUnremarkableMessage() {
    #expect(UndoCommand.suggestedReversals(labelIDs: ["INBOX"]).isEmpty)
}

/// Shared fixture: an isolated temp-file store with one account and one
/// message, so tests never touch the real `~/Library/Application Support`
/// database. `LocalRuntime.local(databaseURL:)`/direct init are the seams —
/// no reliance on `$HOME`, which `HudsonPaths.databaseURL` does not honor.
private func makeTestRuntime(labelIDs: [String]) async throws -> (HudsonDatabase, LocalRuntime) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hudson-undo-test-\(UUID().uuidString)")
    let database = try HudsonDatabase.open(at: dir.appendingPathComponent("db.sqlite"))
    try await AccountsMigration.runIfNeeded(database: database)
    try await database.upsertAccount(
        email: "test@example.com", clientID: "client", consentedAt: Date())
    _ = try await database.applySnapshot(
        MessageSnapshot(
            id: "msg1", threadID: "thread1", historyID: 1, internalDate: 0,
            fromLine: "a@b.com", toLine: "c@d.com", subject: "Hi", snippet: "",
            labelIDs: labelIDs),
        account: "test@example.com")
    let account = try #require(try await database.primaryAccount())
    return (database, LocalRuntime(database: database, account: account))
}
