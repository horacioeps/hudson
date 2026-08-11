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
