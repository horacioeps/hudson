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
@Test func openLoadsMessagesNewestExpandedOlderCollapsed() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedTwoMessageThread(into: db, account: account)

    let model = ThreadModel(database: db, account: account)
    await model.open(threadID: "th1")
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.messages.count == 2)
    #expect(model.messages.map(\.id) == ["th1-m0", "th1-m1"])
    #expect(model.messages[0].isExpanded == false)
    #expect(model.messages[1].isExpanded == true)
    // The expanded (newest) message's body was fetched eagerly on open.
    #expect(model.messages[1].bodyText == "Body of the second (newest) message.")
    // The collapsed (older) message's body is NOT fetched until expanded.
    #expect(model.messages[0].bodyText == nil)
}

@MainActor
@Test func toggleExpandedFlipsStateAndLazilyFetchesBody() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await seedTwoMessageThread(into: db, account: account)

    let model = ThreadModel(database: db, account: account)
    await model.open(threadID: "th1")
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.messages[0].isExpanded == false)
    model.toggleExpanded("th1-m0")
    #expect(model.messages[0].isExpanded == true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.messages[0].bodyText == "Body of the first message.")

    model.toggleExpanded("th1-m0")
    #expect(model.messages[0].isExpanded == false)
    // Collapsing never clears an already-cached body.
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
    try await Task.sleep(for: .milliseconds(50))

    // User expands the older message too, so BOTH are expanded going in.
    model.toggleExpanded("th1-m0")
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.messages[0].isExpanded == true)
    #expect(model.messages[1].isExpanded == true)

    #expect(model.messages[1].row.labelIDs.contains("UNREAD") == false)
    try await Triage.markUnread(messageID: "th1-m1", account: account, database: db)
    try await Task.sleep(for: .milliseconds(50))

    // Label state updated...
    #expect(model.messages[1].row.labelIDs.contains("UNREAD") == true)
    // ...but expand state for both still-present messages was preserved.
    #expect(model.messages[0].isExpanded == true)
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
    try await Task.sleep(for: .milliseconds(50))

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
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.subject == "Re: Proposal draft")
    // "you@hudson.app" (no `Name <email>` form) falls back to its local
    // part, "you" — mirrors `ThreadRollup.senderDisplayName`'s fallback.
    #expect(model.participants == "Priya Anand, you")
}
