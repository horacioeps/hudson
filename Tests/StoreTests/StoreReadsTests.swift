import Foundation
import GRDB
import Testing
@testable import Store

@Test func messageReturnsRowWithNilBodyBeforeHydration() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 5, internalDate: 1_000,
        fromLine: "a@example.com", toLine: "b@example.com",
        subject: "s", snippet: "sn", labelIDs: ["INBOX"])
    _ = try await database.applySnapshot(snapshot, account: "x")

    let result = try #require(try await database.message(id: "m1", account: "x"))
    #expect(result.row.id == "m1")
    #expect(result.row.subject == "s")
    #expect(result.plainText == nil)   // no body hydrated yet
}

@Test func messageReturnsNilForMissingId() async throws {
    let database = try HudsonDatabase.inMemory()
    let result = try await database.message(id: "ghost", account: "x")
    #expect(result == nil)
}

@Test func messageBodyReturnsHTMLAndRemoteInventory() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 5, internalDate: 1_000,
        fromLine: "a@example.com", toLine: "b@example.com",
        subject: "s", snippet: "sn", labelIDs: ["INBOX"])
    _ = try await database.applySnapshot(snapshot, account: "x")

    // A body with a remote image — the sanitizer both keeps the raw HTML and
    // catalogues the remote URL, and `messageBody` must round-trip both.
    let html = Data("<p>Hello</p><img src=\"https://tracker.example/pixel.gif\">".utf8)
    try await database.saveBody(
        messageID: "m1", account: "x",
        body: Sanitizer.sanitize(html: html, plainText: nil))

    let body = try #require(try await database.messageBody(id: "m1", account: "x"))
    #expect(body.rawHTML == html)
    #expect(body.plainText?.contains("Hello") == true)
    #expect(body.remoteURLs.contains("https://tracker.example/pixel.gif"))
    #expect(body.cidReferences.isEmpty)
}

@Test func messageBodyReturnsNilBeforeHydration() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 5, internalDate: 1_000,
        fromLine: "a@example.com", toLine: "b@example.com",
        subject: "s", snippet: "sn", labelIDs: ["INBOX"])
    _ = try await database.applySnapshot(snapshot, account: "x")
    // Message exists but has no `message_bodies` row yet.
    #expect(try await database.messageBody(id: "m1", account: "x") == nil)
    #expect(try await database.messageBody(id: "ghost", account: "x") == nil)
}

@Test func upsertLabelsInsertsThenUpdatesName() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertLabels([(id: "l1", name: "Inbox")], account: "x")
    try await database.upsertLabels([(id: "l1", name: "Primary")], account: "x")

    let name = try await database.writer.read { db in
        try String.fetchOne(
            db, sql: "SELECT name FROM labels WHERE account_email = ? AND id = ?",
            arguments: ["x", "l1"])
    }
    #expect(name == "Primary")
}

// MARK: - Send-as identity (the From header the account already uses)

private func seedSent(
    _ db: HudsonDatabase, account: String, id: String, fromLine: String, date: Int64
) async throws {
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: id, threadID: "t-\(id)", historyID: date, internalDate: date,
            fromLine: fromLine, toLine: "someone@example.com",
            subject: "s", snippet: "sn", labelIDs: ["SENT"]),
        account: account)
}

@Test func sendAsFromLineTakesTheMostFrequentIdentity() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "mannas@example.com"
    try await db.upsertAccount(email: account, clientID: "c", consentedAt: .now)
    for i in 1...5 {
        try await seedSent(
            db, account: account, id: "a\(i)",
            fromLine: "Mannas <\(account)>", date: Int64(i))
    }
    // A stray send from some other tool must not rename the user, even though
    // it is the most RECENT.
    try await seedSent(
        db, account: account, id: "b1", fromLine: "Horizon <\(account)>", date: 99)

    #expect(try await db.sendAsFromLine(account: account) == "Mannas <\(account)>")
}

@Test func sendAsFromLineIgnoresBareAddressesAndOtherPeople() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "mannas@example.com"
    try await db.upsertAccount(email: account, clientID: "c", consentedAt: .now)
    // A bare address carries no name, so it is nothing to adopt...
    try await seedSent(db, account: account, id: "a1", fromLine: account, date: 1)
    try await seedSent(db, account: account, id: "a2", fromLine: account, date: 2)
    // ...and a named header for a DIFFERENT address is somebody else.
    try await seedSent(
        db, account: account, id: "a3", fromLine: "Someone <other@example.com>", date: 3)

    #expect(try await db.sendAsFromLine(account: account) == nil)
}

@Test func sendAsFromLineIsNilWithNoSentMail() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "mannas@example.com"
    try await db.upsertAccount(email: account, clientID: "c", consentedAt: .now)
    // An inbox message from the account's own address is not a SENT message.
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "i1", threadID: "t1", historyID: 1, internalDate: 1,
            fromLine: "Mannas <\(account)>", toLine: account,
            subject: "s", snippet: "sn", labelIDs: ["INBOX"]),
        account: account)

    #expect(try await db.sendAsFromLine(account: account) == nil)
}
