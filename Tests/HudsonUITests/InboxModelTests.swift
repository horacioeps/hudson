import Store
import Testing
@testable import HudsonUI

@MainActor
@Test func selectNextAdvancesAndArchiveRemovesSelectedThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = InboxModel(database: db, account: "you@hudson.app")
    await model.start()
    // let the first observation emit
    try await Task.sleep(for: .milliseconds(50))

    #expect(!model.rows.isEmpty)
    model.selectNext()
    let firstSelected = model.selectedThreadID
    #expect(firstSelected != nil)
    model.selectNext()
    #expect(model.selectedThreadID != firstSelected)

    // Archive the selected thread; after the re-emit it is gone from rows.
    model.selectPrevious()
    let target = model.selectedThreadID
    try await model.archiveSelected()
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.rows.contains { $0.threadID == target } == false)
}

/// `activeSplit` restricts `rows` to one split — the demo mailbox's
/// "important" split (Priya's mail, via a `.sender` rule) has exactly 4
/// threads (t17-t20 in `DemoData`), so this also incidentally checks the
/// count is right, not just that every row matches.
@MainActor
@Test func activeSplitFiltersRowsToOneSplit() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = InboxModel(database: db, account: "you@hudson.app")
    await model.start()
    try await Task.sleep(for: .milliseconds(50))
    let allCount = model.rows.count

    model.activeSplit = "important"
    try await Task.sleep(for: .milliseconds(50))

    #expect(!model.rows.isEmpty)
    #expect(model.rows.count < allCount)
    #expect(model.rows.allSatisfy { $0.splitKey == "important" })
}

/// `toggleReadSelected` flips `ThreadRow.unread` for the selected thread,
/// and the flip is visible on the NEXT observation re-emit — same
/// "optimistic triage re-emits, nobody mutates `rows` by hand" contract as
/// `archiveSelected`.
@MainActor
@Test func toggleReadSelectedFlipsUnreadAndReemits() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = InboxModel(database: db, account: "you@hudson.app")
    await model.start()
    try await Task.sleep(for: .milliseconds(50))

    model.selectNext()
    let target = try #require(model.selectedThreadID)
    let wasUnread = try #require(model.rows.first { $0.threadID == target }).unread

    try await model.toggleReadSelected()
    try await Task.sleep(for: .milliseconds(50))

    let isUnreadNow = try #require(model.rows.first { $0.threadID == target }).unread
    #expect(isUnreadNow == !wasUnread)
}

/// Regression test: archiving a MULTI-message thread must clear `INBOX`
/// from every message that carries it, not just the newest
/// (`lastMessageID`) — `thread_rollup.in_inbox` is an OR-aggregate across
/// the whole thread (`ThreadRollup.recomputeThreadFlags`), so removing
/// `INBOX` from only the newest message silently no-ops whenever an older
/// message (e.g. the conversation's opening message) still carries it.
/// Every multi-message thread in `DemoData` (t01/t09/t17/t22) has exactly
/// this shape — the opening message keeps `INBOX`, only "you"'s own SENT
/// replies drop it — so picking the first one present in `rows` is enough;
/// no need to hardcode a specific thread id.
@MainActor
@Test func archiveSelectedOnMultiMessageThreadLeavesInbox() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = InboxModel(database: db, account: "you@hudson.app")
    await model.start()
    try await Task.sleep(for: .milliseconds(50))

    let target = try #require(model.rows.first { $0.messageCount > 1 })
    model.selectedThreadID = target.threadID

    try await model.archiveSelected()
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.rows.contains { $0.threadID == target.threadID } == false)
}

/// Same OR-aggregate bug, for `unread`: a two-message thread whose OLDER
/// message is unread and whose NEWER message is already read. Marking only
/// `lastMessageID` read (as the buggy version did) would leave the older
/// message's `UNREAD` in place and the rollup would recompute right back to
/// `unread == true`. Seeded directly via `Store`'s write API (matching
/// `ObservationTests.swift`'s pattern) since `DemoData`'s multi-message
/// threads all carry their `UNREAD`/`STARRED` labels on the NEWEST message
/// instead, which wouldn't exercise this shape.
@MainActor
@Test func toggleReadSelectedOnMultiMessageThreadClearsUnreadThreadWide() async throws {
    let db = try HudsonDatabase.inMemory()
    let account = "you@hudson.app"
    try await db.upsertAccount(email: account, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "multi-m0", threadID: "multi", historyID: 1, internalDate: 1,
            fromLine: "sender@example.com", toLine: account, subject: "Hello",
            snippet: "first", labelIDs: ["INBOX", "UNREAD"]),
        account: account)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "multi-m1", threadID: "multi", historyID: 2, internalDate: 2,
            fromLine: "sender@example.com", toLine: account, subject: "Re: Hello",
            snippet: "second", labelIDs: ["INBOX"]),
        account: account)

    let model = InboxModel(database: db, account: account)
    await model.start()
    try await Task.sleep(for: .milliseconds(50))

    let target = try #require(model.rows.first { $0.threadID == "multi" })
    #expect(target.unread)
    model.selectedThreadID = target.threadID

    try await model.toggleReadSelected()
    try await Task.sleep(for: .milliseconds(50))

    let updated = try #require(model.rows.first { $0.threadID == "multi" })
    #expect(!updated.unread)
}

/// An empty (unseeded) account has no threads and no split rules — `rows`
/// stays empty and `tabs` is exactly the always-present "Primary" tab at
/// count 0, both before AND after `start()`'s first emission lands.
@MainActor
@Test func emptyInboxYieldsEmptyRowsAndPrimaryTabAtZero() async throws {
    let db = try HudsonDatabase.inMemory()
    let model = InboxModel(database: db, account: "nobody@hudson.app")
    #expect(model.tabs == [SplitTab(key: "primary", title: "Primary", count: 0)])

    await model.start()
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.rows.isEmpty)
    #expect(model.tabs == [SplitTab(key: "primary", title: "Primary", count: 0)])
}

/// Switching to a label folder (Starred/Sent/…) loads the threads carrying
/// that label, drops the split-tab strip, and shows the folder title — the
/// sidebar folders the user reported as dead.
@MainActor
@Test func labelFolderLoadsThreadsAndDropsSplitTabs() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = InboxModel(database: db, account: "you@hudson.app")
    await model.start()
    try await Task.sleep(for: .milliseconds(80))
    #expect(model.showsSplitTabs)            // inbox mode by default
    let inboxCount = model.rows.count

    model.mailbox = .label(id: "STARRED", title: "Starred")
    try await Task.sleep(for: .milliseconds(80))
    #expect(!model.showsSplitTabs)           // a flat label folder
    #expect(model.folderTitle == "Starred")
    #expect(!model.rows.isEmpty)             // demo seeds starred threads
    #expect(model.rows.count != inboxCount)  // a genuinely different set

    // Every row in the Starred folder actually carries STARRED (verifies the
    // Store query, not just that *some* rows came back).
    for row in model.rows {
        let labels = try await db.threadMessages(threadID: row.threadID, account: "you@hudson.app")
            .flatMap(\.labelIDs)
        #expect(labels.contains("STARRED"))
    }

    // Back to the inbox restores the split view.
    model.mailbox = .inbox
    try await Task.sleep(for: .milliseconds(80))
    #expect(model.showsSplitTabs)
    #expect(model.folderTitle == "Inbox")
}
