import Foundation
import GRDB
import Testing

@testable import AIKit
@testable import Store

private let account = "user@example.com"

/// Seeds one message snapshot. Mirrors `AIStoreTests.snap` — kept local
/// (per-file convention across this codebase) so each test file's fixture
/// shape stays obvious at the call site.
private func snap(
    _ id: String, thread: String = "t1", from: String = "alice@example.com",
    subject: String = "Hello", date: Int64 = 1, labels: [String] = ["INBOX"]
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: from, toLine: "bob@example.com", subject: subject, snippet: "sn",
        labelIDs: labels)
}

/// Drains a `String` stream (what `Summarize.summarize` returns) into an
/// array, mirroring `ScriptedProvider.swift`'s `collect(_:)` for `LLMEvent`.
private func collectText(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var chunks: [String] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

/// Reads back which message ids fed a cached artifact — the provenance
/// `AIArtifacts.purge` walks on a source-message deletion.
private func sourceMessageIDs(
    _ db: HudsonDatabase, kind: String, key: String, model: String, promptVersion: Int
) async throws -> [String] {
    try await db.writer.read { conn in
        try String.fetchAll(
            conn,
            sql: """
                SELECT message_id FROM ai_artifact_sources
                WHERE account_email = ? AND kind = ? AND artifact_key = ? AND model = ?
                  AND prompt_version = ?
                ORDER BY message_id
                """,
            arguments: [account, kind, key, model, promptVersion])
    }
}

// MARK: - RED: cache hit — zero egress

/// A cache hit must yield the cached text and MUST NOT call the provider —
/// re-viewing a summary is a local read, never a network call, regardless of
/// whether the feature is even opted in (no `ai_config` row exists here).
@Test func cacheHitYieldsCachedTextWithNoProviderCall() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 100), account: account)
    _ = try await db.applySnapshot(snap("m2", date: 200), account: account)
    // Cache key is (thread_id, last_message_id) — m2 is newest, so it's the
    // key's second half.
    try await db.putArtifact(
        kind: "summary", key: "t1:m2", model: Summarize.defaultModel, promptVersion: 1,
        content: "cached thread summary", sources: ["m1", "m2"], account: account,
        createdAt: 1_000)
    let provider = ScriptedProvider(script: [.textDelta("SHOULD NOT STREAM"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)

    let stream = try await summarize.summarize(threadID: "t1", invocation: .userInvoked(.summarize))
    let chunks = try await collectText(stream)

    #expect(chunks == ["cached thread summary"])
    #expect(provider.callCount == 0)
}

// MARK: - RED: cache miss — egresses, streams live deltas, caches on completion

/// A miss calls the (opted-in) provider, streams its deltas straight through
/// to the caller, and — once the stream completes — writes the accumulated
/// text to the cache with every thread message recorded as a source.
@Test func cacheMissCallsProviderStreamsDeltasAndCachesWithThreadSources() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", from: "alice@example.com", subject: "Tuesday?", date: 100), account: account)
    _ = try await db.applySnapshot(
        snap("m2", from: "bob@example.com", subject: "Re: Tuesday?", date: 200), account: account)
    try await db.saveBody(
        messageID: "m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Can we meet Tuesday?"))
    try await db.saveBody(
        messageID: "m2", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Works for me."))
    try await db.setAIConfig(
        feature: AIFeature.summarize.rawValue, model: "claude-haiku-4-5", baseURL: nil, optIn: true,
        account: account)
    let script: [LLMEvent] = [
        .textDelta("They "), .textDelta("agreed to meet Tuesday."),
        .usage(inputTokens: 20, outputTokens: 6), .stopped,
    ]
    let provider = ScriptedProvider(script: script)
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)

    let stream = try await summarize.summarize(threadID: "t1", invocation: .userInvoked(.summarize))
    let chunks = try await collectText(stream)

    #expect(chunks == ["They ", "agreed to meet Tuesday."])
    #expect(provider.callCount == 1)
    #expect(provider.lastRequest?.model == "claude-haiku-4-5")
    // Context is built from PLAIN TEXT only (spec §8) — both messages' bodies
    // must be present in the single prompt sent to the provider.
    let promptText = provider.lastRequest?.messages.first?.text ?? ""
    #expect(promptText.contains("Can we meet Tuesday?"))
    #expect(promptText.contains("Works for me."))

    let cached = try await db.artifact(
        kind: "summary", key: "t1:m2", model: "claude-haiku-4-5", promptVersion: 1, account: account)
    #expect(cached == "They agreed to meet Tuesday.")
    let sources = try await sourceMessageIDs(
        db, kind: "summary", key: "t1:m2", model: "claude-haiku-4-5", promptVersion: 1)
    #expect(sources == ["m1", "m2"])
}

// MARK: - RED: not opted in — throws before any egress

/// A cache miss on a feature that has never been opted in throws
/// `AIError.notOptedIn` (from `EgressGuard`, not duplicated here) and never
/// reaches the provider.
@Test func notOptedInThrowsAndNeverCallsProvider() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 100), account: account)
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.summarize)) {
        _ = try await summarize.summarize(threadID: "t1", invocation: .userInvoked(.summarize))
    }
    #expect(provider.callCount == 0)
}

/// Same gate, opt-in explicitly turned off (row exists, `opt_in = false`) —
/// presence of a row is not consent.
@Test func optInFalseThrowsAndNeverCallsProvider() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 100), account: account)
    try await db.setAIConfig(
        feature: AIFeature.summarize.rawValue, model: "claude-haiku-4-5", baseURL: nil, optIn: false,
        account: account)
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.summarize)) {
        _ = try await summarize.summarize(threadID: "t1", invocation: .userInvoked(.summarize))
    }
    #expect(provider.callCount == 0)
}

// MARK: - RED: unknown/empty thread

/// A thread with zero messages (unknown thread id) has no `last_message_id`
/// to key the cache on — throws before any cache lookup or egress.
@Test func summarizingUnknownThreadThrowsEmptyThreadAndNeverCallsProvider() async throws {
    let db = try HudsonDatabase.inMemory()
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)

    await #expect(throws: AIError.emptyThread("does-not-exist")) {
        _ = try await summarize.summarize(
            threadID: "does-not-exist", invocation: .userInvoked(.summarize))
    }
    #expect(provider.callCount == 0)
}

// MARK: - RED: a refusal caches nothing

/// The 5-series contract's `stop_reason == "refusal"` arrives with no usable
/// content — the caller's stream ends with no text, and nothing is cached
/// (a future re-view must retry, not silently replay an empty "summary").
@Test func refusalYieldsNoTextAndCachesNothing() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 100), account: account)
    try await db.setAIConfig(
        feature: AIFeature.summarize.rawValue, model: "claude-haiku-4-5", baseURL: nil, optIn: true,
        account: account)
    let provider = ScriptedProvider(script: [.refusal])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)

    let stream = try await summarize.summarize(threadID: "t1", invocation: .userInvoked(.summarize))
    let chunks = try await collectText(stream)

    #expect(chunks.isEmpty)
    let cached = try await db.artifact(
        kind: "summary", key: "t1:m1", model: "claude-haiku-4-5", promptVersion: 1, account: account)
    #expect(cached == nil)
}

// MARK: - RED: model falls back to the documented default, never hardcoded as the only source

/// With no `ai_config` row, the cache key (and, on a would-be egress, the
/// request) uses the documented default model, not a hardcoded literal
/// disconnected from `Summarize.defaultModel`.
@Test func modelFallsBackToDocumentedDefaultWhenUnconfigured() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 100), account: account)
    try await db.putArtifact(
        kind: "summary", key: "t1:m1", model: Summarize.defaultModel, promptVersion: 1,
        content: "default-model cache hit", sources: ["m1"], account: account, createdAt: 1_000)
    let provider = ScriptedProvider(script: [.stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)

    let stream = try await summarize.summarize(threadID: "t1", invocation: .userInvoked(.summarize))
    let chunks = try await collectText(stream)

    #expect(chunks == ["default-model cache hit"])
    #expect(Summarize.defaultModel == "claude-haiku-4-5")
}
