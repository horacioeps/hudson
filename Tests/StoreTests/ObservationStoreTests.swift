import GRDB
import Testing
@testable import Store

@Test func observeInboxThreadsEmitsThenReemitsAfterArchive() async throws {
    let db = try HudsonDatabase.inMemory()
    try await TestSeed.account(db, "a@b.com")
    try await TestSeed.inboxThread(db, account: "a@b.com", threadID: "t1",
                                   messageID: "m1", subject: "Hello")

    var iterator = db.observeInboxThreads(account: "a@b.com", split: nil, limit: 50)
        .makeAsyncIterator()

    let first = try await iterator.next()
    #expect(first?.contains { $0.threadID == "t1" } == true)

    // Optimistic archive: remove INBOX. enqueueMutation recomputes the rollup
    // in-transaction, so the observation must re-emit without "t1".
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove,
                                 account: "a@b.com", now: 1)
    let second = try await iterator.next()
    #expect(second?.contains { $0.threadID == "t1" } == false)
}
