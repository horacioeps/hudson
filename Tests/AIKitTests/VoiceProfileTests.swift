import Foundation
import GRDB
import Testing

@testable import AIKit
@testable import Store

private let account = "user@example.com"

/// Seeds one message snapshot. Mirrors `SummarizeTests.swift`'s `snap` — kept
/// local (per-file convention across this codebase) so each test file's
/// fixture shape stays obvious at the call site.
private func snap(
    _ id: String, thread: String = "t1", from: String = "alice@example.com",
    subject: String = "Hello", date: Int64 = 1, labels: [String] = ["SENT"]
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: from, toLine: "bob@example.com", subject: subject, snippet: "sn",
        labelIDs: labels)
}

/// Seeds `count` hydrated SENT messages (`m0`, `m1`, ...), each with a
/// distinct hydrated plain-text body — the raw material `current()` folds
/// into `hydratedCount`/the cache fingerprint and, on a miss, the corpus it
/// distills from.
private func seedHydratedSentMessages(_ db: HudsonDatabase, count: Int) async throws {
    for i in 0..<count {
        let id = "m\(i)"
        _ = try await db.applySnapshot(snap(id, date: Int64(i)), account: account)
        try await db.saveBody(
            messageID: id, account: account,
            body: Sanitizer.sanitize(html: nil, plainText: "Sent message body #\(i)."))
    }
}

// MARK: - RED: distilled once, then cached — a hit is zero egress

/// First call (no cache) distills via the provider; a second call with the
/// SAME underlying sent-mail corpus hits the cache and never calls the
/// provider again — the required TDD bullet: "second call no provider hit
/// unless forceRefresh".
@Test func distilledOnceThenCachedSecondCallNoProviderHit() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedHydratedSentMessages(db, count: 3)
    try await db.setAIConfig(
        feature: AIFeature.voiceProfile.rawValue, model: "claude-sonnet-5", baseURL: nil,
        optIn: true, account: account)
    let provider = ScriptedProvider(script: [.textDelta("Casual, "), .textDelta("short sentences."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)

    let first = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(first == "Casual, short sentences.")
    #expect(provider.callCount == 1)
    // The distillation prompt is built from the sent-mail PLAIN TEXT (spec §8).
    #expect(provider.lastRequest?.messages.first?.text.contains("Sent message body #0.") == true)

    let second = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(second == "Casual, short sentences.")
    #expect(provider.callCount == 1)  // unchanged — served from ai_artifacts
}

/// `forceRefresh: true` re-distills even though a cached profile already
/// exists at the same fingerprint — the user-visible "refresh voice profile"
/// path.
@Test func forceRefreshRedistillsEvenWithAnUnchangedCorpus() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedHydratedSentMessages(db, count: 3)
    try await db.setAIConfig(
        feature: AIFeature.voiceProfile.rawValue, model: "claude-sonnet-5", baseURL: nil,
        optIn: true, account: account)
    let provider = ScriptedProvider(script: [.textDelta("A style card."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)

    _ = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(provider.callCount == 1)

    _ = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: true)
    #expect(provider.callCount == 2)
}

// MARK: - RED: not opted in — throws before any egress

@Test func voiceProfileNotOptedInThrowsAndNeverCallsProvider() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedHydratedSentMessages(db, count: 3)
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.voiceProfile)) {
        _ = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    }
    #expect(provider.callCount == 0)
}

// MARK: - RED: a refusal caches nothing

@Test func refusalYieldsEmptyStringAndCachesNothing() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedHydratedSentMessages(db, count: 3)
    try await db.setAIConfig(
        feature: AIFeature.voiceProfile.rawValue, model: "claude-sonnet-5", baseURL: nil,
        optIn: true, account: account)
    let provider = ScriptedProvider(script: [.refusal])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)

    let result = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(result == "")

    // A second call still has nothing cached, so it must call the provider
    // again rather than silently replaying an empty "profile".
    _ = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(provider.callCount == 2)
}

// MARK: - RED: thin corpus regenerates once real coverage backfills in
// (architecture "Corrections that must not be reintroduced": source_fingerprint
// folds in the hydrated-sent-body count + a minimum-corpus threshold.)

/// A profile distilled while the sent-mail corpus is still thin (under the
/// minimum-corpus threshold) is automatically superseded — with NO
/// `forceRefresh` needed — once enough more sent mail hydrates: this is
/// exactly "staleness during an explicit draft" from the task doc, realized
/// as a fingerprint change rather than an explicit flag.
@Test func thinCorpusProfileIsSupersededOnceBackfillCrossesTheThreshold() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedHydratedSentMessages(db, count: 2)  // well under the threshold
    try await db.setAIConfig(
        feature: AIFeature.voiceProfile.rawValue, model: "claude-sonnet-5", baseURL: nil,
        optIn: true, account: account)
    let provider = ScriptedProvider(script: [.textDelta("Early, thin-corpus style card."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)

    let early = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(early == "Early, thin-corpus style card.")
    #expect(provider.callCount == 1)

    // Same tiny count again (e.g. a second explicit draft moments later,
    // still early in backfill) — still a cache hit, no re-egress.
    _ = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(provider.callCount == 1)

    // Backfill (§4.4) hydrates far more sent mail — corpus crosses the
    // minimum threshold.
    try await seedHydratedSentMessages(db, count: 25)

    let after = try await voiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)
    #expect(after == "Early, thin-corpus style card.")  // same script; the point is it re-ran
    #expect(provider.callCount == 2)  // re-distilled without forceRefresh
}
