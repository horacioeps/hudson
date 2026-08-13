import Foundation
import GRDB
import Testing
@testable import Store

/// A store frozen at v9 — the last schema before the sync window — so a test
/// can seed the exact pre-upgrade state (a backfill page token produced by an
/// unfiltered listing) and then run v10 over it.
private func databaseAtV9() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try migrator.migrate(queue, upTo: "v9")
    return queue
}

private func seedAccount(
    _ queue: DatabaseQueue, email: String, state: String, token: String?
) throws {
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO accounts (email, client_id, consented_at, backfill_state,
                    backfill_page_token) VALUES (?, 'c', 0, ?, ?)
                """,
            arguments: [email, state, token])
    }
}

private func backfill(
    _ queue: DatabaseQueue, email: String
) throws -> (state: String, token: String?) {
    try queue.read { db in
        let row = try Row.fetchOne(
            db, sql: "SELECT backfill_state, backfill_page_token FROM accounts WHERE email = ?",
            arguments: [email])!
        return (row["backfill_state"], row["backfill_page_token"])
    }
}

@Test func v10RestartsAnInProgressBackfillUnderTheNewWindow() throws {
    let queue = try databaseAtV9()
    try seedAccount(queue, email: "midway@ex.com", state: "listing", token: "unfiltered-token")

    try migrator.migrate(queue)

    // The stored token continues an UNFILTERED listing and cannot be paired
    // with the window filter the next pass sends — so it must be dropped and
    // the listing restarted, not resumed.
    let result = try backfill(queue, email: "midway@ex.com")
    #expect(result.state == "pending")
    #expect(result.token == nil)
}

@Test func v10LeavesACompletedBackfillAlone() throws {
    let queue = try databaseAtV9()
    try seedAccount(queue, email: "done@ex.com", state: "complete", token: nil)

    try migrator.migrate(queue)

    // Already fully cached: re-listing a narrower window would buy nothing,
    // and flipping this back to "pending" would re-download the mailbox.
    let result = try backfill(queue, email: "done@ex.com")
    #expect(result.state == "complete")
    #expect(result.token == nil)
}
