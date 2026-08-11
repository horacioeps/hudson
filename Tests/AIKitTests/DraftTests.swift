import Foundation
import GRDB
import Testing

@testable import AIKit
@testable import Store

private let account = "user@example.com"

/// Seeds one message snapshot. Mirrors `SummarizeTests.swift`/`VoiceProfileTests.swift`'s
/// `snap` — kept local (per-file convention across this codebase).
private func snap(
    _ id: String, thread: String = "t1", from: String = "alice@example.com",
    subject: String = "Hello", date: Int64 = 1, labels: [String] = ["INBOX"]
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: from, toLine: "bob@example.com", subject: subject, snippet: "sn",
        labelIDs: labels)
}

/// Opts a feature in with a fixed model — kept short since most Draft tests
/// need both `.draft` and `.voiceProfile` opted in.
private func optIn(_ db: HudsonDatabase, feature: AIFeature, model: String) async throws {
    try await db.setAIConfig(
        feature: feature.rawValue, model: model, baseURL: nil, optIn: true, account: account)
}

/// Drains a `String` stream (what `Draft.draft` returns) into an array.
private func collectText(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var chunks: [String] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

// MARK: - RED: draft builds voice + thread + instruction context and streams

/// The drafted text streams live to the caller, and the request sent to the
/// provider for the draft's own generation carries the voice profile, the
/// replied-to thread's content, AND the instruction — the spec §8 egress-table
/// row for Draft, verified by inspecting the actual request.
@Test func draftBuildsVoiceThreadAndInstructionContextAndStreams() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("s0", thread: "sent-thread", date: 1, labels: ["SENT"]), account: account)
    try await db.saveBody(
        messageID: "s0", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Thanks, talk soon!"))
    _ = try await db.applySnapshot(
        snap("m1", from: "alice@example.com", subject: "Lunch?", date: 100), account: account)
    try await db.saveBody(
        messageID: "m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Are you free for lunch Friday?"))
    try await optIn(db, feature: .voiceProfile, model: "claude-sonnet-5")
    try await optIn(db, feature: .draft, model: "claude-sonnet-5")
    // ScriptedProvider replays the SAME script for both the voice-profile
    // distillation call and the draft's own generation call — the assertions
    // below inspect `lastRequest`, i.e. the LAST call (the draft itself).
    let provider = ScriptedProvider(script: [.textDelta("Sure, "), .textDelta("Friday works."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)
    let draft = Draft(guard: egressGuard, voiceProfile: voiceProfile, database: db, account: account)

    let stream = try await draft.draft(
        replyTo: "t1", instruction: "say yes and suggest noon", invocation: .userInvoked(.draft))
    let chunks = try await collectText(stream)

    #expect(chunks == ["Sure, ", "Friday works."])
    #expect(provider.callCount == 2)  // 1 voice-profile distillation + 1 draft generation

    // `lastRequest` is the draft's OWN generation call (the second of the two
    // egresses) — its prompt must carry the distilled voice profile's output
    // (the scripted provider's own reply round-tripped as context, standing
    // in for a real distilled style card), the thread being replied to, and
    // the instruction. (`VoiceProfileTests.swift` separately proves the
    // FIRST call — distillation itself — is built from the sent corpus'
    // plain text.)
    let promptText = provider.lastRequest?.messages.first?.text ?? ""
    #expect(promptText.contains("Voice profile:\nSure, Friday works."))
    #expect(promptText.contains("Are you free for lunch Friday?"))  // thread being replied to
    #expect(promptText.contains("say yes and suggest noon"))  // instruction
    #expect(provider.lastRequest?.model == "claude-sonnet-5")
}

/// A new email (no `replyTo`) skips the thread lookup entirely — only the
/// voice profile and instruction feed the prompt.
@Test func newEmailDraftOmitsThreadContextWhenReplyToIsNil() async throws {
    let db = try HudsonDatabase.inMemory()
    try await optIn(db, feature: .voiceProfile, model: "claude-sonnet-5")
    try await optIn(db, feature: .draft, model: "claude-sonnet-5")
    let provider = ScriptedProvider(script: [.textDelta("Hi there."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)
    let draft = Draft(guard: egressGuard, voiceProfile: voiceProfile, database: db, account: account)

    let stream = try await draft.draft(
        replyTo: nil, instruction: "introduce myself", invocation: .userInvoked(.draft))
    _ = try await collectText(stream)

    let promptText = provider.lastRequest?.messages.first?.text ?? ""
    #expect(!promptText.contains("Thread being replied to"))
    #expect(promptText.contains("introduce myself"))
}

// MARK: - RED: not opted in — throws before the draft's own egress

/// `.draft` not opted in throws `notOptedIn(.draft)` even though
/// `.voiceProfile` IS opted in (so the voice-profile step itself succeeds) —
/// the required TDD bullet: "not-opted-in throws".
@Test func draftNotOptedInThrowsAndNeverGenerates() async throws {
    let db = try HudsonDatabase.inMemory()
    try await optIn(db, feature: .voiceProfile, model: "claude-sonnet-5")
    // `.draft` deliberately left unconfigured.
    let provider = ScriptedProvider(script: [.textDelta("style card"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)
    let draft = Draft(guard: egressGuard, voiceProfile: voiceProfile, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.draft)) {
        _ = try await draft.draft(replyTo: nil, instruction: "hi", invocation: .userInvoked(.draft))
    }
    // The voice-profile distillation still ran (its own gate passed) but the
    // draft's own generation never reached the provider.
    #expect(provider.callCount == 1)
}

/// Opting into `.draft` does NOT implicitly opt into `.voiceProfile` — the
/// two features are gated independently (spec §8: per-feature opt-in). With
/// no cached profile and `.voiceProfile` never configured, the FIRST egress
/// attempted (the distillation) is the one that throws.
@Test func voiceProfileNotOptedInThrowsEvenWhenDraftIs() async throws {
    let db = try HudsonDatabase.inMemory()
    try await optIn(db, feature: .draft, model: "claude-sonnet-5")
    // `.voiceProfile` deliberately left unconfigured.
    let provider = ScriptedProvider(script: [.textDelta("nope"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)
    let draft = Draft(guard: egressGuard, voiceProfile: voiceProfile, database: db, account: account)

    await #expect(throws: AIError.notOptedIn(.voiceProfile)) {
        _ = try await draft.draft(replyTo: nil, instruction: "hi", invocation: .userInvoked(.draft))
    }
    #expect(provider.callCount == 0)
}

// MARK: - RED: replying to an unknown/vanished thread

/// A `replyTo` thread id with zero messages fails fast (mirrors
/// `Summarize.emptyThread`) rather than silently drafting a "reply" with no
/// thread context at all.
@Test func replyToUnknownThreadThrowsEmptyThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await optIn(db, feature: .voiceProfile, model: "claude-sonnet-5")
    try await optIn(db, feature: .draft, model: "claude-sonnet-5")
    let provider = ScriptedProvider(script: [.textDelta("style card"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)
    let draft = Draft(guard: egressGuard, voiceProfile: voiceProfile, database: db, account: account)

    await #expect(throws: AIError.emptyThread("does-not-exist")) {
        _ = try await draft.draft(
            replyTo: "does-not-exist", instruction: "hi", invocation: .userInvoked(.draft))
    }
    // The draft's own generation (which would need the thread) never ran —
    // only the voice-profile distillation's provider call did.
    #expect(provider.callCount == 1)
}

// MARK: - RED: a refusal ends the stream with no content

@Test func refusalEndsStreamWithNoContent() async throws {
    let db = try HudsonDatabase.inMemory()
    try await optIn(db, feature: .voiceProfile, model: "claude-sonnet-5")
    try await optIn(db, feature: .draft, model: "claude-sonnet-5")
    // First call (voice profile) succeeds; the SAME script is used for the
    // draft's own call too, so instead we cache the profile with a distinct
    // provider up front, then swap in a refusal-only provider for the draft.
    let seedingProvider = ScriptedProvider(script: [.textDelta("style card"), .stopped])
    let seedingGuard = EgressGuard(provider: seedingProvider, database: db, account: account)
    let seedingVoiceProfile = VoiceProfile(guard: seedingGuard, database: db, account: account)
    _ = try await seedingVoiceProfile.current(invocation: .userInvoked(.voiceProfile), forceRefresh: false)

    let provider = ScriptedProvider(script: [.refusal])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    // Reuses the SAME account's now-cached voice profile — `current` will hit
    // the cache and never call `provider` (the refusal-only one) at all.
    let voiceProfile = VoiceProfile(guard: egressGuard, database: db, account: account)
    let draft = Draft(guard: egressGuard, voiceProfile: voiceProfile, database: db, account: account)

    let stream = try await draft.draft(replyTo: nil, instruction: "hi", invocation: .userInvoked(.draft))
    let chunks = try await collectText(stream)

    #expect(chunks.isEmpty)
    #expect(provider.callCount == 1)  // only the draft's own (refused) call
}
