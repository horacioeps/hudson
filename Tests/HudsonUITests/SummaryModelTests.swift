import Foundation
import GmailKit
import Store
import Synchronization
import Testing

@testable import AIKit
@testable import HudsonUI

/// A test-double `LLMProvider` scoped to HudsonUITests: replays a fixed script
/// of events and counts `stream` calls. `AIKitTests` has its own
/// `ScriptedProvider`, but that lives in a different test target and can't be
/// reached here — so this file carries its own small copy (the same
/// per-file-fixture convention the rest of the codebase follows). The call
/// count is the load-bearing assertion for the privacy tests below: a
/// not-opted-in summarize MUST reach this provider ZERO times.
private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    private let script: [LLMEvent]
    private let calls = Mutex<Int>(0)

    init(script: [LLMEvent]) {
        self.script = script
    }

    var callCount: Int { calls.withLock { $0 } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        calls.withLock { $0 += 1 }
        let script = self.script
        return AsyncThrowingStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

/// A test-double `LLMProvider` whose stream is driven by the test, one event
/// at a time, so a `summarize` run can be paused mid-stream while the test
/// switches threads (`reset()`). It captures the stream's continuation on the
/// first `stream` call; `emit`/`finish` push events through it on demand. Used
/// only by the cross-thread-bleed tests, where deterministic control over WHEN
/// each delta arrives is the whole point.
private final class GatedProvider: LLMProvider, @unchecked Sendable {
    private let cont = Mutex<AsyncThrowingStream<LLMEvent, Error>.Continuation?>(nil)

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            cont.withLock { $0 = continuation }
        }
    }

    /// True once `stream` has been called and the continuation is captured.
    var isStreaming: Bool { cont.withLock { $0 != nil } }

    func emit(_ event: LLMEvent) { cont.withLock { _ = $0?.yield(event) } }
    func finish() { cont.withLock { $0?.finish() } }
}

/// Spins the cooperative scheduler until `predicate` holds or the (generous)
/// bound is hit — the async hops between provider → `EgressGuard` → `Summarize`
/// → `SummaryModel` mean an emitted delta lands a few `Task.yield`s later, and
/// this waits for that propagation without a wall-clock sleep.
@MainActor
private func until(
    _ predicate: () -> Bool, _ message: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
) async {
    for _ in 0..<10_000 {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("timed out waiting: \(message())")
}

/// Seeds one message into `threadID` so `Summarize` has a thread to read
/// (it throws `emptyThread` otherwise) — mirrors `SummarizeTests.snap`'s
/// shape, kept local per this codebase's per-file-fixture convention.
private func seedThread(
    _ db: HudsonDatabase, threadID: String, account: String
) async throws {
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "\(threadID)-m1", threadID: threadID, historyID: 1, internalDate: 1,
            fromLine: "alice@example.com", toLine: "you@hudson.app", subject: "Lunch",
            snippet: "sn", labelIDs: ["INBOX"]),
        account: account)
}

private let account = "you@hudson.app"

// MARK: - RED: opted-in streams a summary into `text`

/// The happy path: with `summarize` opted in, the chip tap streams the
/// provider's deltas into `text` and leaves `needsSetup`/`banner` clear.
/// Drives a REAL `Summarize` over an `EgressGuard` over a `ScriptedProvider`
/// — no network, no Keychain — injected via `SummaryModel`'s factory seam.
@MainActor
@Test func optedInStreamsSummaryIntoText() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedThread(db, threadID: "t1", account: account)
    // `ai config`'s opt-in row — the gate `EgressGuard.run` re-checks.
    try await db.setAIConfig(
        feature: "summarize", model: "claude-haiku-4-5", baseURL: "anthropic", optIn: true,
        account: account)
    let provider = ScriptedProvider(
        script: [.textDelta("Alice"), .textDelta(" wants lunch."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)
    let model = SummaryModel(database: db, account: account, makeSummarize: { summarize })

    await model.summarize(threadID: "t1")

    #expect(model.text == "Alice wants lunch.")
    #expect(model.isStreaming == false)
    #expect(model.needsSetup == false)
    #expect(model.banner == nil)
    #expect(provider.callCount == 1)  // exactly one egress, from the explicit tap
}

// MARK: - RED: not-opted-in sets `needsSetup` and NEVER egresses

/// Privacy #1 — the load-bearing test. With NO opt-in row, tapping the chip
/// must set `needsSetup` and reach the provider ZERO times: `EgressGuard.run`
/// throws `notOptedIn` BEFORE `provider.stream`, so nothing ever leaves the
/// machine. Uses a real `Summarize`/`EgressGuard`/`ScriptedProvider` so this
/// exercises the true egress path, not a stubbed short-circuit.
@MainActor
@Test func notOptedInSetsNeedsSetupAndNeverEgresses() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedThread(db, threadID: "t1", account: account)
    // Deliberately NO `setAIConfig` — the feature is not opted in.
    let provider = ScriptedProvider(script: [.textDelta("SHOULD NOT STREAM"), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)
    let model = SummaryModel(database: db, account: account, makeSummarize: { summarize })

    await model.summarize(threadID: "t1")

    #expect(model.needsSetup == true)
    #expect(model.text.isEmpty)
    #expect(model.isStreaming == false)
    #expect(provider.callCount == 0)  // NEVER egressed — the whole point
}

// MARK: - RED: a nil factory (bootstrap fail-closed) is treated as needs-setup

/// When the production factory (`AIBootstrap.makeSummarize`) returns nil —
/// the fail-closed result when the feature isn't opted in — `SummaryModel`
/// must set `needsSetup` and, obviously, never build or call a provider.
@MainActor
@Test func nilFactorySetsNeedsSetup() async throws {
    let db = try HudsonDatabase.inMemory()
    let model = SummaryModel(database: db, account: account, makeSummarize: { nil })

    await model.summarize(threadID: "t1")

    #expect(model.needsSetup == true)
    #expect(model.text.isEmpty)
    #expect(model.isStreaming == false)
}

// MARK: - AIBootstrap opt-in gating

/// `AIBootstrap.makeSummarize` is fail-closed: no `ai_config` row means the
/// feature was never turned on, so it returns nil (never builds a provider).
/// Injects `InMemoryLLMKeyStore` so CI never touches the real Keychain.
@Test func aiBootstrapReturnsNilWhenNotOptedIn() async throws {
    let db = try HudsonDatabase.inMemory()

    let summarize = await AIBootstrap.makeSummarize(
        database: db, account: account, keyStore: InMemoryLLMKeyStore())

    #expect(summarize == nil)
}

/// An explicit `opt_in = false` row is also fail-closed — matching
/// `EgressGuard`'s own gate — so `makeSummarize` still returns nil.
@Test func aiBootstrapReturnsNilWhenOptInFalse() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(
        feature: "summarize", model: "claude-haiku-4-5", baseURL: "anthropic", optIn: false,
        account: account)

    let summarize = await AIBootstrap.makeSummarize(
        database: db, account: account, keyStore: InMemoryLLMKeyStore())

    #expect(summarize == nil)
}

/// With `opt_in = true`, `makeSummarize` builds a real `Summarize` (a
/// non-nil result). Construction is pure — no network, no Keychain (an empty
/// in-memory key store) — so this asserts the wiring without egressing.
@Test func aiBootstrapReturnsSummarizeWhenOptedIn() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setAIConfig(
        feature: "summarize", model: "claude-haiku-4-5", baseURL: "anthropic", optIn: true,
        account: account)

    let summarize = await AIBootstrap.makeSummarize(
        database: db, account: account, keyStore: InMemoryLLMKeyStore())

    #expect(summarize != nil)
}

// MARK: - Cross-thread bleed: a switch mid-stream must supersede the old run

/// The invariant `openThread`'s `reset()` exists to protect: a summarize begun
/// for one thread must NOT keep writing into the model after the user switches
/// away. Streams thread `t1`'s first delta, then simulates the thread switch by
/// calling `reset()` while the stream is still open, then delivers the REST of
/// `t1`'s deltas. Post-reset deltas must land NOWHERE (`text` stays empty) and
/// `isStreaming` must be false so the new thread's chip is immediately usable —
/// not stranded "Summarizing…" until the old network stream drains.
@MainActor
@Test func switchMidStreamDropsOldThreadDeltas() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedThread(db, threadID: "t1", account: account)
    try await db.setAIConfig(
        feature: "summarize", model: "claude-haiku-4-5", baseURL: "anthropic", optIn: true,
        account: account)
    let provider = GatedProvider()
    let egressGuard = EgressGuard(provider: provider, database: db, account: account)
    let summarize = Summarize(guard: egressGuard, database: db, account: account)
    let model = SummaryModel(database: db, account: account, makeSummarize: { summarize })

    // Kick off the (paused) summarize for t1 and let its first delta land.
    let run = Task { await model.summarize(threadID: "t1") }
    await until({ provider.isStreaming }, "provider stream never opened")
    provider.emit(.textDelta("OLD-A"))
    await until({ model.text == "OLD-A" }, "first delta never streamed into text")
    #expect(model.isStreaming == true)

    // The user switches threads: reset() supersedes the in-flight run.
    model.reset()
    #expect(model.text.isEmpty)
    #expect(model.isStreaming == false)  // new thread's chip must be tappable now

    // The OLD run's remaining deltas arrive AFTER the switch — they must be
    // dropped, never appended into the now-reset model.
    provider.emit(.textDelta("OLD-B"))
    provider.emit(.stopped)
    provider.finish()
    await run.value

    #expect(model.text.isEmpty)  // no cross-thread bleed
    #expect(model.isStreaming == false)
    #expect(model.needsSetup == false)
    #expect(model.banner == nil)
}

/// After a mid-stream switch, a fresh summarize for the NEW thread runs
/// cleanly — its token owns `isStreaming`, and the superseded old run finishing
/// afterward neither reopens the flag nor overwrites the new summary. Guards
/// the supersede-then-restart path `openThread` + an explicit tap produce.
@MainActor
@Test func newSummarizeAfterSwitchIsUnaffectedByOldRun() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seedThread(db, threadID: "t1", account: account)
    try await seedThread(db, threadID: "t2", account: account)
    try await db.setAIConfig(
        feature: "summarize", model: "claude-haiku-4-5", baseURL: "anthropic", optIn: true,
        account: account)

    let oldProvider = GatedProvider()
    let newProvider = ScriptedProvider(script: [.textDelta("NEW summary"), .stopped])
    // The factory hands out the paused provider first, the scripted one after —
    // one Summarize per tap, mirroring how `makeSummarize` is rebuilt per run.
    let calls = Mutex<Int>(0)
    let makeSummarize: () async -> Summarize? = {
        let n = calls.withLock { c -> Int in defer { c += 1 }; return c }
        let p: any LLMProvider = n == 0 ? oldProvider : newProvider
        return Summarize(
            guard: EgressGuard(provider: p, database: db, account: account),
            database: db, account: account)
    }
    let model = SummaryModel(database: db, account: account, makeSummarize: makeSummarize)

    // Start t1, land its first delta, then switch away (reset).
    let oldRun = Task { await model.summarize(threadID: "t1") }
    await until({ oldProvider.isStreaming }, "old provider never opened")
    oldProvider.emit(.textDelta("OLD"))
    await until({ model.text == "OLD" }, "old delta never landed")
    model.reset()

    // Summarize the NEW thread — a fully independent run.
    await model.summarize(threadID: "t2")
    #expect(model.text == "NEW summary")
    #expect(model.isStreaming == false)

    // The old run drains AFTER the new summary is in place — it must not
    // reopen `isStreaming` or clobber the new thread's text.
    oldProvider.emit(.textDelta("-STALE"))
    oldProvider.emit(.stopped)
    oldProvider.finish()
    await oldRun.value

    #expect(model.text == "NEW summary")
    #expect(model.isStreaming == false)
    #expect(model.banner == nil)
    #expect(model.needsSetup == false)
}
