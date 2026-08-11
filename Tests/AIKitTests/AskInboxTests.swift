import Foundation
import GRDB
import Testing

@testable import AIKit
@testable import Store

private let account = "user@example.com"

/// Seeds one message snapshot. Mirrors `SummarizeTests.swift`/`DraftTests.swift`'s
/// `snap` — kept local (per-file convention across this codebase).
private func snap(
    _ id: String, thread: String? = nil, from: String = "alice@example.com",
    subject: String = "Hello", date: Int64 = 1, labels: [String] = ["INBOX"]
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread ?? "t-\(id)", historyID: date, internalDate: date,
        fromLine: from, toLine: "bob@example.com", subject: subject, snippet: "sn",
        labelIDs: labels)
}

/// Opts `.ask` in with a fixed model — kept short since most tests here need it.
private func optInAsk(_ db: HudsonDatabase, model: String = "claude-sonnet-5") async throws {
    try await db.setAIConfig(
        feature: AIFeature.ask.rawValue, model: model, baseURL: nil, optIn: true, account: account)
}

/// Drains an `AskEvent` stream into an array.
private func collect(_ stream: AsyncThrowingStream<AskEvent, Error>) async throws -> [AskEvent] {
    var events: [AskEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

/// Concatenates every `.textDelta` in an `AskEvent` array — the assembled
/// answer text, ignoring the trailing `.citations`/`.coverage` events.
private func answerText(_ events: [AskEvent]) -> String {
    events.compactMap {
        if case .textDelta(let text) = $0 { return text }
        return nil
    }.joined()
}

// MARK: - RED: retrieval selects the seeded relevant messages, cited in the answer

/// A lexical (keyword) query retrieves only the messages that actually match
/// it — proven by seeding both relevant and irrelevant messages and asserting
/// the final `.citations` event names exactly the relevant ones. Also covers
/// the required TDD bullet "lexical query skips expansion": a one-word query
/// with no trailing "?" reads as a keyword search, so only ONE provider call
/// (the answer itself) happens — no Haiku expansion hop.
@Test func retrievalSelectsSeededRelevantMessagesAndCitesThem() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", subject: "Invoice for March", date: 300), account: account)
    try await db.saveBody(
        messageID: "m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Please find the March invoice attached."))
    _ = try await db.applySnapshot(
        snap("m2", subject: "Re: Invoice for March", date: 200), account: account)
    try await db.saveBody(
        messageID: "m2", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Thanks, the invoice looks correct."))
    _ = try await db.applySnapshot(
        snap("m3", subject: "Lunch Friday?", date: 100), account: account)
    try await db.saveBody(
        messageID: "m3", account: account, body: Sanitizer.sanitize(html: nil, plainText: "Noon works."))
    try await optInAsk(db)
    let provider = ScriptedProvider(script: [.textDelta("The March invoice was sent."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let askInbox = AskInbox(guard: egressGuard, database: db, account: account)

    let stream = try await askInbox.ask("invoice", invocation: .userInvoked(.ask))
    let events = try await collect(stream)

    #expect(answerText(events) == "The March invoice was sent.")
    // m1/m2 match "invoice"; m3 ("Lunch Friday?") does not — and must NOT be cited.
    // Newest-first: m1 (date 300) before m2 (date 200).
    #expect(events.contains(.citations(["m1", "m2"])))
    // Both cited messages are hydrated — full coverage.
    #expect(events.contains(.coverage(hydratedFraction: 1.0)))
    #expect(provider.callCount == 1)  // lexical query — no expansion hop
    let promptText = provider.lastRequest?.messages.first?.text ?? ""
    #expect(promptText.contains("Please find the March invoice attached."))
    #expect(promptText.contains("Thanks, the invoice looks correct."))
    #expect(!promptText.contains("Noon works."))
}

// MARK: - RED: a natural-language question triggers the Haiku expansion hop

/// A multi-word question ending in "?" is NOT a keyword search — it triggers
/// the optional Haiku query-expansion hop BEFORE the Sonnet answer hop, so
/// two provider calls happen instead of one. Beyond the call count, this also
/// proves the full expansion→retrieval→citation pipeline: the raw question
/// itself ("What is the status of the contract renewal?") does NOT lexically
/// match m1's indexed content (FTS5's implicit AND rejects "What"/"is"/"of",
/// none of which appear in m1), so retrieval depends entirely on the
/// expansion hop's alternate phrase actually reaching a second `searchMessages`
/// call and matching. `ScriptedProvider(scripts:)` gives the expansion hop and
/// the answer hop DISTINCT scripted responses (a single shared script — the
/// bug this test used to have — would make the expansion hop's "search
/// phrase" literally equal the final answer text, which also fails to match
/// m1 and would let a broken pipeline pass by accident).
@Test func nonLexicalQuestionTriggersExpansionHopBeforeTheAnswer() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", subject: "Contract renewal", date: 100), account: account)
    try await db.saveBody(
        messageID: "m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "The contract renews next month."))
    try await optInAsk(db)
    let provider = ScriptedProvider(scripts: [
        // Expansion hop: an alternate search phrase whose every term appears
        // in m1's subject ("Contract renewal"), so the second (unioned)
        // `searchMessages` pass in `retrieve` actually finds it.
        [.textDelta("contract renewal"), .stopped],
        // Answer hop: distinct text, so the assertions below can tell the two
        // hops apart instead of both trivially matching one shared script.
        [.textDelta("It renews next month."), .stopped],
    ])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let askInbox = AskInbox(guard: egressGuard, database: db, account: account)

    let stream = try await askInbox.ask(
        "What is the status of the contract renewal?", invocation: .userInvoked(.ask))
    let events = try await collect(stream)

    #expect(provider.callCount == 2)  // 1 expansion hop + 1 answer hop
    // The expansion phrase's retrieval hit — m1 — is what gets cited; the
    // raw question alone would have retrieved nothing (see doc comment).
    #expect(events.contains(.citations(["m1"])))
    #expect(events.contains(.coverage(hydratedFraction: 1.0)))
    // The streamed answer text is the ANSWER hop's script, not the expansion
    // hop's search phrase leaking through.
    #expect(answerText(events) == "It renews next month.")
}

// MARK: - RED: not opted in — throws before any egress, including expansion

@Test func askNotOptedInThrowsAndNeverCallsProvider() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Invoice"), account: account)
    // `.ask` deliberately left unconfigured.
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let askInbox = AskInbox(guard: egressGuard, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.ask)) {
        _ = try await askInbox.ask("invoice", invocation: .userInvoked(.ask))
    }
    #expect(provider.callCount == 0)
}

// MARK: - RED: hydration coverage reflects partially-hydrated retrieved messages

/// One of two retrieved messages has no saved body yet (mid-backfill, §4.4) —
/// the final `.coverage` event must report exactly half, not silently treat
/// the un-hydrated placeholder as full coverage.
@Test func coverageReflectsPartiallyHydratedRetrievedMessages() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", subject: "Budget review", date: 200), account: account)
    try await db.saveBody(
        messageID: "m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "The budget review is attached."))
    // m2 matches the query by subject alone — its body was never hydrated.
    _ = try await db.applySnapshot(
        snap("m2", subject: "Budget review follow-up", date: 100), account: account)
    try await optInAsk(db)
    let provider = ScriptedProvider(script: [.textDelta("Here's what I found."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let askInbox = AskInbox(guard: egressGuard, database: db, account: account)

    let stream = try await askInbox.ask("budget", invocation: .userInvoked(.ask))
    let events = try await collect(stream)

    #expect(events.contains(.citations(["m1", "m2"])))
    #expect(events.contains(.coverage(hydratedFraction: 0.5)))
}

// MARK: - RED: no matching messages — graceful, not a throw

/// Zero retrieval hits doesn't throw (unlike `Summarize.emptyThread` for a
/// caller-supplied bad thread id — an inbox genuinely having nothing relevant
/// is a normal outcome, not a caller bug). Citations come back empty and
/// coverage is vacuously full (nothing to hydrate).
@Test func noMatchingMessagesAnswersGracefullyWithNoCitations() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Lunch Friday?"), account: account)
    try await db.saveBody(messageID: "m1", account: account, body: Sanitizer.sanitize(html: nil, plainText: "Noon works."))
    try await optInAsk(db)
    let provider = ScriptedProvider(script: [.textDelta("I couldn't find anything about that."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let askInbox = AskInbox(guard: egressGuard, database: db, account: account)

    let stream = try await askInbox.ask("submarine periscope", invocation: .userInvoked(.ask))
    let events = try await collect(stream)

    #expect(answerText(events) == "I couldn't find anything about that.")
    #expect(events.contains(.citations([])))
    #expect(events.contains(.coverage(hydratedFraction: 1.0)))
}

// MARK: - RED: a refusal still surfaces citations/coverage

/// The 5-series contract's `stop_reason == "refusal"` yields no answer text,
/// but retrieval already happened — citations/coverage are surfaced anyway
/// (architecture: "Ask-inbox/search always surface hydration coverage"),
/// rather than being silently dropped alongside the missing answer.
@Test func refusalStillSurfacesCitationsAndCoverage() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Invoice"), account: account)
    try await db.saveBody(messageID: "m1", account: account, body: Sanitizer.sanitize(html: nil, plainText: "The invoice."))
    try await optInAsk(db)
    let provider = ScriptedProvider(script: [.refusal])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let askInbox = AskInbox(guard: egressGuard, database: db, account: account)

    let stream = try await askInbox.ask("invoice", invocation: .userInvoked(.ask))
    let events = try await collect(stream)

    #expect(answerText(events).isEmpty)
    #expect(events.contains(.citations(["m1"])))
    #expect(events.contains(.coverage(hydratedFraction: 1.0)))
}

// MARK: - RED: the request carries ai_config's configured model, not a hardcoded constant

/// Proves `resolvedModel()`'s plumbing: the model that reaches the request is
/// whatever `ai_config` has configured for `.ask`, not some literal baked
/// into the request path. Deliberately configures a model DIFFERENT from
/// `AskInbox.defaultModel` so the assertion can't be satisfied by coincidence.
///
/// This does NOT (and, unlike `Summarize.modelFallsBackToDocumentedDefaultWhenUnconfigured`,
/// CANNOT) test the `?? AskInbox.defaultModel` fallback branch itself:
/// `AskInbox` has no cache-first path that could let `resolvedModel()`'s
/// output surface without ALSO passing `EgressGuard`'s identical opt-in check
/// on that same `ai_config` row, and `ai_config.model` is `NOT NULL` — so any
/// row that clears the opt-in gate always carries an explicit model. There is
/// no reachable state where `.ask` is opted in (so the request actually
/// fires) and the fallback constant is what supplied the model.
@Test func askUsesAIConfigsConfiguredModelNotTheHardcodedDefault() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", subject: "Invoice"), account: account)
    try await db.saveBody(messageID: "m1", account: account, body: Sanitizer.sanitize(html: nil, plainText: "The invoice."))
    let configuredModel = "claude-opus-5"
    #expect(configuredModel != AskInbox.defaultModel)
    try await optInAsk(db, model: configuredModel)
    let provider = ScriptedProvider(script: [.textDelta("ok"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let askInbox = AskInbox(guard: egressGuard, database: db, account: account)

    let stream = try await askInbox.ask("invoice", invocation: .userInvoked(.ask))
    _ = try await collect(stream)

    #expect(provider.lastRequest?.model == configuredModel)
}
