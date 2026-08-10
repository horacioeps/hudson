import Foundation
import GmailKit
import Store
import Testing
@testable import SyncEngine

private func makeSyncedWorld() async throws -> (ScriptedGmail, HudsonDatabase, SyncEngine) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail()
    let engine = SyncEngine(api: gmail, database: database, account: "x")
    _ = try await engine.syncOnce()  // records cursor 100, completes empty backfill
    return (gmail, database, engine)
}

private func historyPage(_ json: String) -> HistoryPage {
    try! JSONDecoder().decode(HistoryPage.self, from: Data(json.utf8))
}

@Test func historyEventsApplyInOrderAndAdvanceCursor() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistory([historyPage("""
        {"historyId": "120", "history": [
          {"id": "110", "messagesAdded": [{"message":
            {"id": "m1", "threadId": "t1", "historyId": "110",
             "internalDate": "1000", "labelIds": ["INBOX", "UNREAD"], "snippet": "sn",
             "payload": {"headers": [{"name": "Subject", "value": "s"}]}}}]},
          {"id": "115", "labelsRemoved": [{"message":
            {"id": "m1", "threadId": "t1", "historyId": "115", "labelIds": ["INBOX"]}}]}
        ]}
        """)])
    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 2)
    let row = try #require(try await database.recentMessages(account: "x", limit: 1).first)
    #expect(row.labelIDs == ["INBOX"])  // UNREAD removed by the later event
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 120)
}

@Test func unknownLabelEventHydratesTheMessage() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setMessages(["mX": testMessage(id: "mX", historyID: "118")])
    await gmail.setHistory([historyPage("""
        {"historyId": "119", "history": [
          {"id": "118", "labelsAdded": [{"message":
            {"id": "mX", "threadId": "t9", "historyId": "118", "labelIds": ["INBOX"]}}]}
        ]}
        """)])
    _ = try await engine.syncOnce()
    // The unknown id was hydrated via metadata get, not applied blind.
    #expect(try await database.recentMessages(account: "x", limit: 5).map(\.id) == ["mX"])
}

@Test func expiredCursorResetsBackfillAndRefreshesCursor() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistoryError(GmailError.invalidRequest(status: 404, message: "expired"))
    await gmail.setProfileHistoryID("500")
    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 0)
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 500)       // fresh cursor recorded
    #expect(account.backfillState != "complete")  // re-list scheduled
}
