import Foundation
import Testing

@testable import AIKit
@testable import Store

private let account = "user@example.com"

private func request(model: String = "claude-haiku-4-5") -> LLMRequest {
    LLMRequest(
        model: model, system: "you summarize",
        messages: [LLMMessage(role: .user, text: "hello")], maxTokens: 256)
}

// MARK: - opt-in gate is fail-closed

/// No `ai_config` row at all → the feature was never turned on → egress is
/// refused and the provider is NEVER called.
@Test func absentConfigThrowsNotOptedInAndNeverCallsProvider() async throws {
    let db = try HudsonDatabase.inMemory()
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let guardActor = EgressGuard(provider: provider, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.summarize)) {
        _ = try await guardActor.run(request(), for: .userInvoked(.summarize))
    }
    #expect(provider.callCount == 0)
}

/// A row exists but `opt_in = false` → still refused, still zero provider
/// calls. Presence of a config row is not consent; the flag is.
@Test func optInFalseThrowsNotOptedIn() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(
        feature: AIFeature.summarize.rawValue, model: "claude-haiku-4-5",
        baseURL: nil, optIn: false, account: account)
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let guardActor = EgressGuard(provider: provider, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.summarize)) {
        _ = try await guardActor.run(request(), for: .userInvoked(.summarize))
    }
    #expect(provider.callCount == 0)
}

/// Opt-in is per feature: summarize opted in must NOT open egress for draft.
@Test func optInIsPerFeature() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(
        feature: AIFeature.summarize.rawValue, model: "claude-haiku-4-5",
        baseURL: nil, optIn: true, account: account)
    let provider = ScriptedProvider(script: [.stopped])
    let guardActor = EgressGuard(provider: provider, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.draft)) {
        _ = try await guardActor.run(request(), for: .userInvoked(.draft))
    }
    #expect(provider.callCount == 0)
}

// MARK: - opted-in path forwards to the provider

/// With `opt_in = true`, `run` forwards the exact request and streams the
/// scripted events back to the caller.
@Test func optInTrueForwardsRequestAndStreamsEvents() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(
        feature: AIFeature.summarize.rawValue, model: "claude-haiku-4-5",
        baseURL: nil, optIn: true, account: account)
    let script: [LLMEvent] = [
        .textDelta("Hel"), .textDelta("lo"),
        .usage(inputTokens: 10, outputTokens: 2), .stopped,
    ]
    let provider = ScriptedProvider(script: script)
    let guardActor = EgressGuard(provider: provider, database: db, account: account)

    let stream = try await guardActor.run(request(model: "claude-haiku-4-5"),
                                          for: .userInvoked(.summarize))
    let events = try await collect(stream)

    #expect(provider.callCount == 1)
    #expect(provider.lastRequest?.model == "claude-haiku-4-5")
    #expect(events == script)
}

// MARK: - Invocation is mintable only via userInvoked (compile-time)

/// The ONLY way to obtain an `Invocation` is `userInvoked`; its initializer is
/// `private`, so `Invocation(feature:)` would not compile. This test documents
/// the factory and asserts it carries the feature through. The negative case
/// (fabricating one) is enforced by the compiler, not runtime — see
/// `Invocation`'s private init.
@Test func invocationCarriesFeatureFromUserInvoked() {
    let invocation = Invocation.userInvoked(.ask)
    #expect(invocation.feature == .ask)
    // Compile-time guarantee (uncomment to verify it fails to build):
    // _ = Invocation(feature: .ask)  // error: 'init(feature:)' is inaccessible
}
