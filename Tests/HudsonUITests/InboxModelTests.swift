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
