import GmailKit
import Store
import Testing
@testable import SyncEngine

@Test func cursorAdvancesOnlyAfterAllHistoryPagesApplied() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail()
    let engine = SyncEngine(api: gmail, database: db, account: "x")
    _ = try await engine.syncOnce()  // seeds cursor 100 (default profile), empty backfill

    // Both new ids arrive as minimal history stubs; the engine reconciles each
    // with a metadata get, so both must be served.
    await gmail.setMessages([
        "m1": testMessage(id: "m1", historyID: "110", labels: ["INBOX"]),
        "m2": testMessage(id: "m2", historyID: "120", labels: ["INBOX"]),
    ])
    // Two-page history poll: page 1 has nextPageToken, page 2 finishes; both carry historyId 130.
    await gmail.setHistory([
        historyPage(#"{"historyId":"130","nextPageToken":"p2","history":[{"id":"110","messagesAdded":[{"message":{"id":"m1","threadId":"t","historyId":"110","internalDate":"1","labelIds":["INBOX"],"snippet":"s","payload":{"headers":[{"name":"Subject","value":"a"}]}}}]}]}"#),
        historyPage(#"{"historyId":"130","history":[{"id":"120","messagesAdded":[{"message":{"id":"m2","threadId":"t","historyId":"120","internalDate":"2","labelIds":["INBOX"],"snippet":"s","payload":{"headers":[{"name":"Subject","value":"b"}]}}}]}]}"#),
    ])
    _ = try await engine.syncOnce()
    // Both messages applied AND the cursor advanced exactly once to 130.
    #expect(try await db.recentMessages(account: "x", limit: 10).map(\.id).sorted() == ["m1", "m2"])
    let cursor = try await db.writer.read { try Int64.fetchOne($0, sql: "SELECT history_cursor FROM accounts WHERE email='x'") }
    #expect(cursor == 130)
}

/// Fault-injection `GmailAPI`: forwards to `inner`, but throws on the Nth
/// call to `listHistory` — simulates a process crash between history pages
/// (after earlier pages' changes have already reached the store). An actor
/// (not a struct) so its own call counter is isolated from `inner`'s
/// `historyCalls` log, which may already carry calls from an earlier pass.
private actor CrashingAfterNthHistoryCall: GmailAPI {
    private let inner: ScriptedGmail
    private let crashOnCall: Int
    private var historyCallCount = 0

    init(inner: ScriptedGmail, crashOnCall: Int) {
        self.inner = inner
        self.crashOnCall = crashOnCall
    }

    func getProfile() async throws -> Profile { try await inner.getProfile() }
    func listMessages(pageToken: String?, maxResults: Int) async throws -> MessageListPage {
        try await inner.listMessages(pageToken: pageToken, maxResults: maxResults)
    }
    func getMessage(id: String, format: String) async throws -> GmailMessage {
        try await inner.getMessage(id: id, format: format)
    }
    func listHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        historyCallCount += 1
        if historyCallCount == crashOnCall {
            struct SimulatedCrash: Error {}
            throw SimulatedCrash()
        }
        return try await inner.listHistory(startHistoryID: startHistoryID, pageToken: pageToken)
    }
    func listLabels() async throws -> [GmailLabel] { try await inner.listLabels() }
    func modify(id: String, addLabelIDs: [String], removeLabelIDs: [String]) async throws -> GmailMessage {
        try await inner.modify(id: id, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs)
    }
    func batchModify(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws {
        try await inner.batchModify(ids: ids, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs)
    }
}

@Test func crashBetweenHistoryPagesLeavesCursorUnadvanced() async throws {
    // Direct regression for the M2-deferred bug: a crash between pages must
    // NOT leave the cursor already jumped to Gmail's reported (final-mailbox)
    // historyId — only page 1's changes may exist when this crash hits.
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail()
    let seedEngine = SyncEngine(api: gmail, database: db, account: "x")
    _ = try await seedEngine.syncOnce()  // seeds cursor 100, empty backfill

    // Page 1's m1 arrives as a minimal stub, reconciled via a metadata get on
    // `gmail` (the crashing wrapper forwards getMessage to it). m2 is on page 2,
    // which the crash prevents from ever being fetched — registered anyway so
    // the mock stays honest.
    await gmail.setMessages([
        "m1": testMessage(id: "m1", historyID: "110", labels: ["INBOX"]),
        "m2": testMessage(id: "m2", historyID: "120", labels: ["INBOX"]),
    ])
    await gmail.setHistory([
        historyPage(#"{"historyId":"130","nextPageToken":"p2","history":[{"id":"110","messagesAdded":[{"message":{"id":"m1","threadId":"t","historyId":"110","internalDate":"1","labelIds":["INBOX"],"snippet":"s","payload":{"headers":[{"name":"Subject","value":"a"}]}}}]}]}"#),
        historyPage(#"{"historyId":"130","history":[{"id":"120","messagesAdded":[{"message":{"id":"m2","threadId":"t","historyId":"120","internalDate":"2","labelIds":["INBOX"],"snippet":"s","payload":{"headers":[{"name":"Subject","value":"b"}]}}}]}]}"#),
    ])
    // Crashes right before page 2's listHistory call — page 1 has already
    // been applied to the store by then.
    let crashing = CrashingAfterNthHistoryCall(inner: gmail, crashOnCall: 2)
    let crashingEngine = SyncEngine(api: crashing, database: db, account: "x")
    await #expect(throws: (any Error).self) {
        _ = try await crashingEngine.syncOnce()
    }
    // Page 1's change landed...
    #expect(try await db.recentMessages(account: "x", limit: 10).map(\.id) == ["m1"])
    // ...but the cursor must still be the OLD value. Gmail reports its
    // *current mailbox* historyId (130) on every page, so committing it
    // after page 1 alone would make a later re-poll believe page 2 already
    // happened, permanently losing it. Only advancing once, after the whole
    // pagination succeeds, keeps a crash here safely re-pollable.
    let cursor = try await db.writer.read { try Int64.fetchOne($0, sql: "SELECT history_cursor FROM accounts WHERE email='x'") }
    #expect(cursor == 100)
}
