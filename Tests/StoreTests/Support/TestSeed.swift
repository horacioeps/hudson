import Foundation
@testable import Store

/// Shared test-only seeding helpers for the observation/reactive-read
/// suites. Both go through the real write path (`upsertAccount`/
/// `applySnapshot`) so `thread_rollup` ends up populated exactly the way
/// production sync populates it — never by hand-writing rollup rows, which
/// would let a test pass against a shape `ThreadRollup` itself would never
/// produce.
enum TestSeed {
    /// Registers a bare account row — the identity most reads and the
    /// mutation queue are scoped by.
    static func account(_ db: HudsonDatabase, _ email: String) async throws {
        try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: .now)
    }

    /// One hydrated, unread inbox message in a fresh thread — applied as a
    /// snapshot (not a hand-written rollup row) so `ThreadRollup.maintainRollup`
    /// populates `thread_rollup` the same way a real sync would.
    static func inboxThread(
        _ db: HudsonDatabase, account: String, threadID: String, messageID: String,
        subject: String, date: Int64 = 1
    ) async throws {
        _ = try await db.applySnapshot(
            MessageSnapshot(
                id: messageID, threadID: threadID, historyID: date, internalDate: date,
                fromLine: "sender@example.com", toLine: "you@example.com", subject: subject,
                snippet: "snippet", labelIDs: ["INBOX", "UNREAD"]),
            account: account)
    }
}
