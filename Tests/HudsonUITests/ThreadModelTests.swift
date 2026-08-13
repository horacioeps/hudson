import Foundation
import Store
import Testing

@testable import HudsonUI

/// Seeds a two-message thread directly via Store's public write APIs
/// (`upsertAccount`/`applySnapshot`/`saveBody`) — matching
/// `ObservationTests`'/`InboxModelTests`' pattern — rather than the full
/// `DemoData` mailbox, so each test's shape (message count, which message
/// has a body, which labels) is explicit and doesn't depend on `DemoData`'s
/// content staying stable.
@MainActor
private func seedTwoMessageThread(into db: HudsonDatabase, account: String) async throws {
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th1-m0", threadID: "th1", historyID: 1, internalDate: 1000,
            fromLine: "Ada Lovelace <ada@example.com>", toLine: account, subject: "Analytical Engine",
            snippet: "first message", labelIDs: ["INBOX"]),
        account: account)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th1-m1", threadID: "th1", historyID: 2, internalDate: 2000,
            fromLine: "Ada Lovelace <ada@example.com>", toLine: account,
            subject: "Re: Analytical Engine", snippet: "second message",
            labelIDs: ["INBOX"]),
        account: account)
    try await db.saveBody(
        messageID: "th1-m0", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Body of the first message."),
        attachments: [])
    try await db.saveBody(
        messageID: "th1-m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Body of the second (newest) message."),
        attachments: [])
}

@MainActor
@Test func openExpandsEveryMessageAndFetchesEachBody() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedTwoMessageThread(into: db, account: account)

    let model = ThreadModel(database: db, account: account)
    await model.open(threadID: "th1")
    // `allSatisfy` is vacuously true on an empty array, so the emptiness
    // check is what makes this wait for the first emission rather than
    // sailing straight through it.
    try await waitUntil {
        !model.messages.isEmpty && model.messages.allSatisfy { $0.bodyText != nil }
    }

    #expect(model.messages.count == 2)
    #expect(model.messages.map(\.id) == ["th1-m0", "th1-m1"])
    // The reading pane presents a thread as a continuous conversation, so a
    // message opens expanded and its body is fetched — not one open message
    // above a stack of stubs (Pencil "Thread (Expanded)").
    #expect(model.messages[0].isExpanded == true)
    #expect(model.messages[1].isExpanded == true)
    #expect(model.messages[0].bodyText == "Body of the first message.")
    #expect(model.messages[1].bodyText == "Body of the second (newest) message.")
}

@MainActor
@Test func toggleExpandedFlipsStateAndLazilyFetchesBody() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedTwoMessageThread(into: db, account: account)

    let model = ThreadModel(database: db, account: account)
    await model.open(threadID: "th1")
    try await waitUntil {
        !model.messages.isEmpty && model.messages.allSatisfy { $0.bodyText != nil }
    }

    // Messages now open expanded, so the first toggle COLLAPSES.
    #expect(model.messages[0].isExpanded == true)
    #expect(model.messages[0].bodyText == "Body of the first message.")

    model.toggleExpanded("th1-m0")
    #expect(model.messages[0].isExpanded == false)
    // Collapsing never clears an already-cached body...
    #expect(model.messages[0].bodyText == "Body of the first message.")

    // ...so re-expanding is instant, with no second fetch.
    model.toggleExpanded("th1-m0")
    #expect(model.messages[0].isExpanded == true)
    #expect(model.messages[0].bodyText == "Body of the first message.")
}

/// The core regression this task exists to prevent: a re-emit from
/// `observeThread` (here, triggered by a mark-unread on the newest
/// message) must update label state WITHOUT resetting the user's
/// expand/collapse choices for messages that are still present.
@MainActor
@Test func reemitUpdatesLabelStateWhilePreservingExpandState() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedTwoMessageThread(into: db, account: account)

    let model = ThreadModel(database: db, account: account)
    await model.open(threadID: "th1")
    try await waitUntil { model.messages.count == 2 }

    // User COLLAPSES the older message, so the two differ going in — a
    // re-emit that reset state would be invisible if both matched the default.
    model.toggleExpanded("th1-m0")
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.messages[0].isExpanded == false)
    #expect(model.messages[1].isExpanded == true)

    #expect(model.messages[1].row.labelIDs.contains("UNREAD") == false)
    try await Triage.markUnread(messageID: "th1-m1", account: account, database: db)
    try await waitUntil { model.messages[1].row.labelIDs.contains("UNREAD") }

    // Label state updated...
    #expect(model.messages[1].row.labelIDs.contains("UNREAD") == true)
    // ...but expand state for both still-present messages was preserved,
    // including the hand-collapsed one, which must NOT snap back to the
    // expanded default.
    #expect(model.messages[0].isExpanded == false)
    #expect(model.messages[1].isExpanded == true)
}

/// The reading pane can only render real HTML mail if `ThreadModel` carries
/// the raw HTML (and the sanitizer's remote-URL inventory) through to the
/// view — this proves an HTML body's `rawHTML`/`remoteURLs` reach `messages`
/// after `open`, eagerly, for the newest (auto-expanded) message.
@MainActor
@Test func openExposesRawHTMLAndRemoteURLsForHTMLBody() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th3-m0", threadID: "th3", historyID: 1, internalDate: 1000,
            fromLine: "Sale <deals@shop.example>", toLine: account, subject: "Sale",
            snippet: "sn", labelIDs: ["INBOX"]),
        account: account)
    let html = Data("<p>Hi</p><img src=\"https://cdn.shop.example/hero.png\">".utf8)
    try await db.saveBody(
        messageID: "th3-m0", account: account,
        body: Sanitizer.sanitize(html: html, plainText: nil), attachments: [])

    let model = ThreadModel(database: db, account: account)
    await model.open(threadID: "th3")
    try await waitUntil { model.messages.first?.rawHTML != nil }

    let message = try #require(model.messages.first)
    #expect(message.isExpanded)  // newest -> auto-expanded -> body fetched eagerly
    #expect(message.rawHTML == html)
    #expect(message.remoteURLs.contains("https://cdn.shop.example/hero.png"))
}

@MainActor
@Test func subjectAndParticipantsDeriveFromNewestMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th2-m0", threadID: "th2", historyID: 1, internalDate: 1000,
            fromLine: "Priya Anand <priya@meridian.example>", toLine: account,
            subject: "Proposal draft", snippet: "first",
            labelIDs: ["INBOX"]),
        account: account)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th2-m1", threadID: "th2", historyID: 2, internalDate: 2000,
            fromLine: account, toLine: "priya@meridian.example",
            subject: "Re: Proposal draft", snippet: "second",
            labelIDs: []),
        account: account)

    let model = ThreadModel(database: db, account: account)
    await model.open(threadID: "th2")
    try await waitUntil { !model.subject.isEmpty }

    #expect(model.subject == "Re: Proposal draft")
    // "you@hudson.app" (no `Name <email>` form) falls back to its local
    // part, "you" — mirrors `ThreadRollup.senderDisplayName`'s fallback.
    #expect(model.participants == "Priya Anand, you")
}

// MARK: - On-demand hydration (`hydrateBody`) — the reading pane's fix for
// a message that's expanded but hasn't been reached yet by the background
// `SyncEngine.hydrateBodies()` batch (capped at 25/pass; a large backfill
// can starve it indefinitely). `hydrateBody` is `ThreadModel`'s injected
// seam onto `SyncEngine.hydrate(messageID:)` — these tests script it
// directly rather than standing up a real network stack, matching how
// `ThreadModel`'s other tests script Store directly rather than Gmail.

/// Records every id `hydrateBody` was invoked with — an `actor` so it's
/// safe to mutate from the `@Sendable` closure `ThreadModel` calls it
/// through, and to read back from `@MainActor` test code.
private actor HydrateBodyRecorder {
    private(set) var calls: [String] = []
    func record(_ id: String) { calls.append(id) }
}

@MainActor
@Test func expandingABodylessMessageHydratesOnDemandExactlyOnceAndCaches() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th4-m0", threadID: "th4", historyID: 1, internalDate: 1000,
            fromLine: "Ada Lovelace <ada@example.com>", toLine: account,
            subject: "Not hydrated yet", snippet: "sn", labelIDs: ["INBOX"]),
        account: account)
    // Deliberately no `saveBody` — has_body stays 0, exactly what a
    // backfilled row the background hydration batch hasn't reached yet
    // looks like.

    let recorder = HydrateBodyRecorder()
    let model = ThreadModel(
        database: db, account: account,
        hydrateBody: { id in
            await recorder.record(id)
            // Mirrors `SyncEngine.hydrate`'s real contract: on success it
            // has ALREADY saved the body to Store before returning `true`.
            try? await db.saveBody(
                messageID: id, account: account,
                body: Sanitizer.sanitize(html: nil, plainText: "Fetched on demand"),
                attachments: [])
            return true
        })

    await model.open(threadID: "th4")
    try await waitUntil { model.messages.first?.bodyText != nil }

    #expect(model.messages.count == 1)
    #expect(model.messages[0].isExpanded)  // sole message -> newest -> auto-expanded
    #expect(model.messages[0].bodyText == "Fetched on demand")
    #expect(await recorder.calls == ["th4-m0"])
}

@Test @MainActor func hydrateBodyIsNotCalledWhenTheLocalBodyAlreadyExists() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    // Both messages already have locally-hydrated bodies (`seedTwoMessageThread`).
    try await seedTwoMessageThread(into: db, account: account)

    let recorder = HydrateBodyRecorder()
    let model = ThreadModel(
        database: db, account: account,
        hydrateBody: { id in
            await recorder.record(id)
            return true
        })

    await model.open(threadID: "th1")
    // Both messages are expanded on open, and both already have LOCAL
    // bodies — so both must resolve without ever reaching for the network.
    try await waitUntil {
        !model.messages.isEmpty && model.messages.allSatisfy { $0.bodyText != nil }
    }

    #expect(model.messages[0].bodyText == "Body of the first message.")
    #expect(model.messages[1].bodyText == "Body of the second (newest) message.")
    #expect(await recorder.calls.isEmpty)
}

/// The concurrency guard this task exists to add: `toggleExpanded`'s
/// independent unstructured `Task` racing a SAME-thread re-emit's
/// `loadBodiesForExpandedMessages` for the SAME id must not fire two
/// overlapping fetches for that id.
///
/// This — not a re-emit racing `open`'s OWN eager on-open fetch — is the
/// genuine race `inFlightHydrations` exists to guard: both `open`'s eager
/// fetch and every re-emit's fetch run inside the SAME `observationTask`
/// for-loop (see `open`'s doc comment / `ThreadModel.swift`), which can't
/// dequeue emission N+1 until emission N's `await
/// loadBodiesForExpandedMessages()` — including any `hydrateBody` await
/// inside it — has already returned. That loop therefore can never race
/// itself, no matter how the guard is implemented; a test pitting the two
/// against each other (as this test used to) can pass even with the guard
/// deleted entirely. `toggleExpanded`, by contrast, fires a genuinely
/// independent `Task` (`ThreadModel.swift`, `toggleExpanded`'s doc
/// comment) that CAN still be in flight when a re-emit's
/// `loadBodiesForExpandedMessages` runs — exactly the scenario below.
@MainActor
@Test func toggleExpandedRacingASameThreadReemitDoesNotDuplicateAnInFlightHydration() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    // "th7-m1" already has a LOCAL body, so its on-open fetch never touches
    // `hydrateBody`. "th7-m0" has none and is the message under test: its
    // FIRST hydrate (the one `open` fires) deliberately fails, leaving it
    // expanded-with-no-body and nothing in flight, which is the state a
    // collapse/re-expand needs in order to fire `toggleExpanded`'s own
    // independent `Task` — the only genuine racer, per the note above.
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th7-m0", threadID: "th7", historyID: 1, internalDate: 1000,
            fromLine: "Ada Lovelace <ada@example.com>", toLine: account,
            subject: "Slow hydrate", snippet: "sn", labelIDs: ["INBOX"]),
        account: account)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th7-m1", threadID: "th7", historyID: 2, internalDate: 2000,
            fromLine: "Ada Lovelace <ada@example.com>", toLine: account,
            subject: "Re: Slow hydrate", snippet: "sn2", labelIDs: ["INBOX"]),
        account: account)
    try await db.saveBody(
        messageID: "th7-m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Already hydrated"), attachments: [])

    let recorder = HydrateBodyRecorder()
    let model = ThreadModel(
        database: db, account: account,
        hydrateBody: { id in
            let isFirstAttempt = await recorder.calls.isEmpty
            await recorder.record(id)
            // The on-open attempt fails fast and saves nothing, so the
            // message is left uncached with no fetch outstanding.
            guard !isFirstAttempt else { return false }
            // Wide enough that the sibling-triggered re-emit below lands
            // WHILE this fetch is still in flight, giving the in-flight
            // guard something to actually guard.
            try? await Task.sleep(for: .milliseconds(120))
            try? await db.saveBody(
                messageID: id, account: account,
                body: Sanitizer.sanitize(html: nil, plainText: "Hydrated"),
                attachments: [])
            return true
        })

    await model.open(threadID: "th7")
    try await waitUntil { !model.messages.isEmpty }
    // The on-open attempt is async and its failure leaves `bodyText` nil, so
    // there is no view state to poll — wait on the recorder itself.
    // (`waitUntil`'s condition is synchronous and can't await the actor.)
    for _ in 0..<300 where await recorder.calls.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    // Expanded by default, but its body fetch failed, so it is still uncached.
    #expect(model.messages[0].isExpanded == true)
    #expect(model.messages[0].bodyText == nil)
    #expect(await recorder.calls == ["th7-m0"])

    // Collapse, then re-expand: THAT expand is what fires `toggleExpanded`'s
    // own unstructured `Task`, independent of `observationTask`.
    model.toggleExpanded("th7-m0")
    #expect(model.messages[0].isExpanded == false)
    model.toggleExpanded("th7-m0")
    #expect(model.messages[0].isExpanded == true)

    // While that fetch is still asleep, a re-emit lands (a label change on
    // the SIBLING message, "th7-m1") — `observationTask`'s loop calls
    // `loadBodiesForExpandedMessages()` again, which still sees "th7-m0" as
    // expanded-with-no-body and, without the in-flight guard, fires a
    // SECOND, overlapping fetch for it.
    try await Task.sleep(for: .milliseconds(30))
    try await Triage.markUnread(messageID: "th7-m1", account: account, database: db)
    try await Task.sleep(for: .milliseconds(200))

    // Two calls total — the failed on-open attempt and the re-expand — and
    // crucially NOT a third from the re-emit that landed mid-flight.
    #expect(await recorder.calls == ["th7-m0", "th7-m0"])
    #expect(model.messages[0].bodyText == "Hydrated")
}

/// Under a `nil` hydrateBody (the `--demo`/no-Keychain-creds case), a
/// body-less message stays exactly as uncached as it was before on-demand
/// hydration existed — no fetch, no crash, nothing to await.
@MainActor
@Test func nilHydrateBodyLeavesABodylessMessageUncached() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "th6-m0", threadID: "th6", historyID: 1, internalDate: 1000,
            fromLine: "Ada Lovelace <ada@example.com>", toLine: account,
            subject: "No hydrator wired", snippet: "sn", labelIDs: ["INBOX"]),
        account: account)

    let model = ThreadModel(database: db, account: account)  // hydrateBody defaults to nil
    await model.open(threadID: "th6")
    try await waitUntil { !model.messages.isEmpty }

    #expect(model.messages[0].isExpanded)
    #expect(model.messages[0].bodyText == nil)
}
