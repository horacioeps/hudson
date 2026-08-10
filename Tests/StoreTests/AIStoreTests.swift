import Foundation
import GRDB
import Testing
@testable import Store

private func snap(
    _ id: String, thread: String = "t1", labels: [String] = ["INBOX"],
    date: Int64 = 1
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: "a@x.com", toLine: "b@x.com", subject: "s-\(id)", snippet: "sn", labelIDs: labels)
}

private func artifactSourceCount(
    _ db: HudsonDatabase, account: String = "x"
) async throws -> Int {
    try await db.writer.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM ai_artifact_sources WHERE account_email = ?",
                          arguments: [account]) ?? -1
    }
}

private func artifactRowCount(
    _ db: HudsonDatabase, account: String = "x"
) async throws -> Int {
    try await db.writer.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM ai_artifacts WHERE account_email = ?",
                          arguments: [account]) ?? -1
    }
}

// MARK: - RED: content-addressed cache round trip

@Test func putThenGetArtifactRoundTrips() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "the summary", sources: ["m1", "m2"], account: "x", createdAt: 1_000)
    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1, account: "x")
    #expect(content == "the summary")
}

@Test func artifactCacheMissWhenNeverWritten() async throws {
    let db = try HudsonDatabase.inMemory()
    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1, account: "x")
    #expect(content == nil)
}

@Test func artifactCacheMissOnPromptVersionBump() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "v1 summary", sources: [], account: "x", createdAt: 1_000)
    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 2, account: "x")
    #expect(content == nil)
}

@Test func artifactCacheMissOnDifferentModel() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "v1 summary", sources: [], account: "x", createdAt: 1_000)
    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-y", promptVersion: 1, account: "x")
    #expect(content == nil)
}

@Test func artifactIsScopedPerAccount() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "acct a", sources: [], account: "a@x.com", createdAt: 1_000)
    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1, account: "b@x.com")
    #expect(content == nil)
}

// MARK: - RED: put is an upsert, not an append

@Test func putArtifactUpsertsContentInPlace() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "first draft", sources: ["m1"], account: "x", createdAt: 1_000)
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "revised draft", sources: ["m1", "m2"], account: "x", createdAt: 2_000)
    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1, account: "x")
    #expect(content == "revised draft")
    #expect(try await artifactRowCount(db) == 1)   // no duplicate row
    #expect(try await artifactSourceCount(db) == 2)   // old source set replaced, not appended
}

// MARK: - RED: purge-on-delete — deleteVanishedMessage path

@Test func sourceMessageDeletionPurgesItsArtifactViaDeleteVanishedMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    _ = try await db.applySnapshot(snap("m2"), account: "x")
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "thread summary", sources: ["m1", "m2"], account: "x", createdAt: 1_000)

    try await db.deleteVanishedMessage(id: "m1", account: "x")

    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1, account: "x")
    #expect(content == nil)
    #expect(try await artifactRowCount(db) == 0)
    #expect(try await artifactSourceCount(db) == 0)   // both source rows go, not just m1's
}

// MARK: - RED: purge-on-delete — .deleted history branch

@Test func sourceMessageDeletionPurgesItsArtifactViaDeletedHistoryEvent() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "thread summary", sources: ["m1"], account: "x", createdAt: 1_000)

    _ = try await db.applyHistoryChanges([HistoryChange(kind: .deleted(id: "m1"))], account: "x")

    let content = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1, account: "x")
    #expect(content == nil)
    #expect(try await artifactRowCount(db) == 0)
}

// MARK: - RED: purge is scoped to artifacts sourced from the deleted message

@Test func purgeOnlyRemovesArtifactsSourcedFromDeletedMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    _ = try await db.applySnapshot(snap("m2"), account: "x")
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "summary sourced from m1", sources: ["m1"], account: "x", createdAt: 1_000)
    try await db.putArtifact(
        kind: "summary", key: "t2", model: "claude-x", promptVersion: 1,
        content: "summary sourced from m2", sources: ["m2"], account: "x", createdAt: 1_000)

    try await db.deleteVanishedMessage(id: "m1", account: "x")

    let purged = try await db.artifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1, account: "x")
    let untouched = try await db.artifact(
        kind: "summary", key: "t2", model: "claude-x", promptVersion: 1, account: "x")
    #expect(purged == nil)
    #expect(untouched == "summary sourced from m2")
}

// MARK: - Fix wave 2: ai_artifact_sources stores composite key parts, not a rowid

@Test func sourcesStoreCompositeArtifactKeyPartsNotAnArtifactRowid() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    try await db.putArtifact(
        kind: "summary", key: "t1", model: "claude-x", promptVersion: 1,
        content: "the summary", sources: ["m1"], account: "x", createdAt: 1_000)

    // Extracted into a Sendable tuple inside the closure (rather than
    // returned as a raw `Row`, which GRDB deliberately doesn't make
    // Sendable) — the standard shape for a `db.writer.read` fetch from an
    // async test, mirroring `rollupRow`'s pattern in `ThreadRollupTests.swift`.
    let fetched: (kind: String, key: String, model: String, promptVersion: Int, messageID: String)? =
        try await db.writer.read { conn in
            guard
                let row = try Row.fetchOne(
                    conn,
                    sql: "SELECT * FROM ai_artifact_sources WHERE account_email = ? AND message_id = ?",
                    arguments: ["x", "m1"])
            else { return nil }
            return (
                kind: row["kind"], key: row["artifact_key"], model: row["model"],
                promptVersion: row["prompt_version"], messageID: row["message_id"])
        }
    let row = try #require(fetched)
    // The source row carries the artifact's OWN composite primary-key
    // parts directly — no separate rowid indirection to go stale.
    #expect(row.kind == "summary")
    #expect(row.key == "t1")
    #expect(row.model == "claude-x")
    #expect(row.promptVersion == 1)
    #expect(row.messageID == "m1")
}

@Test func artifactWithNoSourcesSurvivesUnrelatedMessageDeletion() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1"), account: "x")
    // A voice-profile-style artifact with no per-message provenance.
    try await db.putArtifact(
        kind: "voice-profile", key: "global", model: "claude-x", promptVersion: 1,
        content: "voice profile", sources: [], account: "x", createdAt: 1_000)

    try await db.deleteVanishedMessage(id: "m1", account: "x")

    let content = try await db.artifact(
        kind: "voice-profile", key: "global", model: "claude-x", promptVersion: 1, account: "x")
    #expect(content == "voice profile")
}

// MARK: - RED: ai_config round trip + upsert

@Test func aiConfigReturnsNilWhenNeverConfigured() async throws {
    let db = try HudsonDatabase.inMemory()
    let config = try await db.aiConfig(feature: "summarize", account: "x")
    #expect(config == nil)
}

@Test func setAIConfigThenAIConfigRoundTrips() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(
        feature: "summarize", model: "claude-x", baseURL: "https://api.example.com", optIn: true,
        account: "x")
    let config = try #require(try await db.aiConfig(feature: "summarize", account: "x"))
    #expect(config.model == "claude-x")
    #expect(config.baseURL == "https://api.example.com")
    #expect(config.optIn == true)
}

@Test func setAIConfigDefaultsBaseURLToNil() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(feature: "summarize", model: "claude-x", baseURL: nil, optIn: false, account: "x")
    let config = try #require(try await db.aiConfig(feature: "summarize", account: "x"))
    #expect(config.baseURL == nil)
    #expect(config.optIn == false)
}

@Test func setAIConfigUpsertsInPlace() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(feature: "summarize", model: "claude-x", baseURL: nil, optIn: false, account: "x")
    try await db.setAIConfig(feature: "summarize", model: "claude-y", baseURL: "https://y.example.com", optIn: true, account: "x")
    let config = try #require(try await db.aiConfig(feature: "summarize", account: "x"))
    #expect(config.model == "claude-y")
    #expect(config.baseURL == "https://y.example.com")
    #expect(config.optIn == true)
    let rowCount = try await db.writer.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM ai_config WHERE account_email = ? AND feature = ?",
                          arguments: ["x", "summarize"]) ?? -1
    }
    #expect(rowCount == 1)
}

@Test func aiConfigIsScopedPerFeatureAndAccount() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(feature: "summarize", model: "claude-x", baseURL: nil, optIn: true, account: "x")
    #expect(try await db.aiConfig(feature: "draft", account: "x") == nil)
    #expect(try await db.aiConfig(feature: "summarize", account: "y") == nil)
}

// MARK: - RED: threadMessages — ordered oldest-first, thread/account scoped

@Test func threadMessagesOrderedOldestFirst() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m3", thread: "t1", date: 300), account: "x")
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m2", thread: "t1", date: 200), account: "x")

    let rows = try await db.threadMessages(threadID: "t1", account: "x")
    #expect(rows.map(\.id) == ["m1", "m2", "m3"])
}

@Test func threadMessagesExcludesOtherThreadsAndAccounts() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t1", date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m2", thread: "t2", date: 200), account: "x")
    _ = try await db.applySnapshot(snap("m3", thread: "t1", date: 300), account: "y")

    let rows = try await db.threadMessages(threadID: "t1", account: "x")
    #expect(rows.map(\.id) == ["m1"])
}

@Test func threadMessagesIsOverlayAware() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", thread: "t1", labels: ["INBOX"], date: 100), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "STARRED", op: .add, account: "x", now: 1)

    let rows = try await db.threadMessages(threadID: "t1", account: "x")
    #expect(rows.first?.labelIDs.contains("STARRED") == true)
}

// MARK: - RED: sentMessages — SENT-filtered, newest-first, overlay-aware, limited

@Test func sentMessagesFiltersToSentLabelNewestFirst() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", labels: ["SENT"], date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m2", labels: ["INBOX"], date: 200), account: "x")
    _ = try await db.applySnapshot(snap("m3", labels: ["SENT"], date: 300), account: "x")

    let rows = try await db.sentMessages(account: "x", limit: 10)
    #expect(rows.map(\.id) == ["m3", "m1"])
}

@Test func sentMessagesRespectsLimit() async throws {
    let db = try HudsonDatabase.inMemory()
    for i in 0..<5 {
        _ = try await db.applySnapshot(snap("m\(i)", labels: ["SENT"], date: Int64(i)), account: "x")
    }
    let rows = try await db.sentMessages(account: "x", limit: 2)
    #expect(rows.count == 2)
    #expect(rows.map(\.id) == ["m4", "m3"])
}

@Test func sentMessagesReflectsPendingAddOverlay() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", labels: ["INBOX"], date: 100), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "SENT", op: .add, account: "x", now: 1)

    let rows = try await db.sentMessages(account: "x", limit: 10)
    #expect(rows.map(\.id) == ["m1"])
}

@Test func sentMessagesReflectsPendingRemoveOverlay() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", labels: ["SENT"], date: 100), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "SENT", op: .remove, account: "x", now: 1)

    let rows = try await db.sentMessages(account: "x", limit: 10)
    #expect(rows.isEmpty)
}

@Test func sentMessagesExcludesOtherAccounts() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", labels: ["SENT"], date: 100), account: "x")
    _ = try await db.applySnapshot(snap("m2", labels: ["SENT"], date: 200), account: "y")

    let rows = try await db.sentMessages(account: "x", limit: 10)
    #expect(rows.map(\.id) == ["m1"])
}
