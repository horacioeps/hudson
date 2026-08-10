import Foundation
import GRDB
import Testing
@testable import Store

private func snap(
    _ id: String, thread: String = "t1", subject: String = "Quarterly report",
    from: String = "ada@x.com", to: String = "you@x.com", labels: [String] = ["INBOX"],
    date: Int64 = 1
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: from, toLine: to, subject: subject, snippet: "sn", labelIDs: labels)
}

private func body(_ plainText: String) -> SanitizedBody {
    SanitizedBody(
        rawHTML: nil, plainText: plainText, sanitizerVersion: Sanitizer.version,
        cidReferences: [], remoteURLs: [])
}

// MARK: - RED: subject + body are both searchable

@Test func searchFindsHitsBySubjectAndBody() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: body("the numbers are in this document"))
    _ = try await db.applySnapshot(snap("m2", subject: "Lunch plans"), account: "x")
    try await db.saveBody(messageID: "m2", account: "x", body: body("let's eat at noon"))

    let bySubject = try await db.searchMessages(account: "x", query: "quarterly", limit: 10)
    #expect(bySubject.map(\.messageID) == ["m1"])

    let byBody = try await db.searchMessages(account: "x", query: "numbers", limit: 10)
    #expect(byBody.map(\.messageID) == ["m1"])
}

// MARK: - RED: bm25 column weights rank a subject match over a body-only match

@Test func ranksSubjectMatchOverBodyOnlyMatch() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Unrelated subject"), account: "x")
    try await db.saveBody(
        messageID: "m1", account: "x", body: body("mentions rocket somewhere in the body text"))
    _ = try await db.applySnapshot(snap("m2", subject: "Rocket launch update"), account: "x")
    try await db.saveBody(messageID: "m2", account: "x", body: body("no relevant terms here"))

    let hits = try await db.searchMessages(account: "x", query: "rocket", limit: 10)
    #expect(hits.map(\.messageID) == ["m2", "m1"])
}

// MARK: - RED: prefix index — a partial token matches the full word

@Test func prefixQueryMatchesLongerToken() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    let hits = try await db.searchMessages(account: "x", query: "quart", limit: 10)
    #expect(hits.map(\.messageID) == ["m1"])
}

// MARK: - RED: 2-char floor

@Test func queryUnderTwoCharsReturnsEmpty() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    #expect(try await db.searchMessages(account: "x", query: "q", limit: 10) == [])
    #expect(try await db.searchMessages(account: "x", query: "  a  ", limit: 10) == [])
    #expect(try await db.searchMessages(account: "x", query: "", limit: 10) == [])
    #expect(try await db.searchMessages(account: "x", query: "   ", limit: 10) == [])
}

// MARK: - RED: overlay scope — an optimistically-archived hit drops out of .inbox

@Test func inboxScopeExcludesOptimisticallyArchivedHit() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(
        snap("m1", subject: "Quarterly report", labels: ["INBOX"]), account: "x")

    let beforeArchive = try await db.searchMessages(
        account: "x", query: "quarterly", limit: 10, scope: .inbox)
    #expect(beforeArchive.map(\.messageID) == ["m1"])

    // Optimistic archive — no server round trip, no history event applied yet.
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)

    let afterArchive = try await db.searchMessages(
        account: "x", query: "quarterly", limit: 10, scope: .inbox)
    #expect(afterArchive.isEmpty)

    let allScope = try await db.searchMessages(
        account: "x", query: "quarterly", limit: 10, scope: .all)
    #expect(allScope.map(\.messageID) == ["m1"])  // .all is unaffected by scope
}

@Test func inboxScopeSurfacesAnOptimisticallyReAddedHit() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(
        snap("m1", subject: "Quarterly report", labels: ["ARCHIVED"]), account: "x")
    #expect(
        try await db.searchMessages(account: "x", query: "quarterly", limit: 10, scope: .inbox)
            .isEmpty)

    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .add, account: "x", now: 1)

    let rows = try await db.searchMessages(account: "x", query: "quarterly", limit: 10, scope: .inbox)
    #expect(rows.map(\.messageID) == ["m1"])
}

// MARK: - RED: default scope is .all

@Test func defaultScopeIsAll() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(
        snap("m1", subject: "Quarterly report", labels: ["ARCHIVED"]), account: "x")
    let hits = try await db.searchMessages(account: "x", query: "quarterly", limit: 10)
    #expect(hits.map(\.messageID) == ["m1"])
}

// MARK: - RED: injection-safe MATCH — FTS5 syntax characters never crash the query

@Test func fts5SyntaxCharactersInQueryDoNotCrash() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    let malicious = [
        "\"; DROP TABLE messages; --",
        "foo \"bar",
        "quarterly OR subject:*",
        "NEAR(a b)",
        "a AND b",
        "-quarterly",
        "col:evil*",
        "\"\"\"\"",
        "((()))",
        "^leading",
        "{subject to}: quarterly",
    ]
    for query in malicious {
        // Must not throw regardless of what FTS5 syntax it superficially contains.
        _ = try await db.searchMessages(account: "x", query: query, limit: 10)
    }
}

@Test func columnFilterSyntaxIsTreatedAsLiteralTextNotAColumnOperator() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    // "subject:quarterly" is ordinary FTS5 column-filter syntax; here it must
    // be treated as a literal phrase (which appears nowhere), never parsed
    // as "search the subject column for quarterly".
    let hits = try await db.searchMessages(account: "x", query: "subject:quarterly", limit: 10)
    #expect(hits.isEmpty)
}

@Test func orKeywordIsTreatedAsALiteralSearchTermNotAnOperator() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    _ = try await db.applySnapshot(snap("m2", subject: "Totally unrelated"), account: "x")
    // A bare "OR" would normally union two clauses in FTS5 syntax; quoted as
    // a literal term it must not match either message's real content.
    let hits = try await db.searchMessages(account: "x", query: "quarterly OR unrelated", limit: 10)
    #expect(hits.isEmpty)
}

// MARK: - RED: SearchHit fields are joined back from `messages` via `message_seq`

@Test func searchHitFieldsAreJoinedFromMessages() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", thread: "t1", subject: "Quarterly report", from: "ada@x.com", date: 555),
        account: "x")
    let hit = try #require(
        try await db.searchMessages(account: "x", query: "quarterly", limit: 10).first)
    #expect(hit.messageID == "m1")
    #expect(hit.threadID == "t1")
    #expect(hit.subject == "Quarterly report")
    #expect(hit.fromLine == "ada@x.com")
    #expect(hit.snippet == "sn")
    #expect(hit.internalDate == 555)
}

// MARK: - RED: LIMIT is honored

@Test func limitCapsResultCount() async throws {
    let db = try HudsonDatabase.inMemory()
    for i in 0..<5 {
        _ = try await db.applySnapshot(
            snap("m\(i)", subject: "Quarterly report \(i)", date: Int64(i)), account: "x")
    }
    let hits = try await db.searchMessages(account: "x", query: "quarterly", limit: 2)
    #expect(hits.count == 2)
}

// MARK: - RED: results are scoped to the requesting account

@Test func searchIsScopedToTheRequestingAccount() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "x")
    _ = try await db.applySnapshot(snap("m1", subject: "Quarterly report"), account: "y")
    let hits = try await db.searchMessages(account: "x", query: "quarterly", limit: 10)
    #expect(hits.count == 1)
}
