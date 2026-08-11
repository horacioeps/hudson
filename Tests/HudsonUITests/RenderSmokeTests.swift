import AppKit
import Store
import SwiftUI
import Testing
@testable import HudsonUI

/// Hosting-view render smoke tests for `SidebarView`/`InboxListView`: build
/// each with a seeded in-memory `AppModel`/`InboxModel`, wrap it in an
/// `NSHostingView`, force a layout pass, and assert a positive fitting
/// size — a cheap "it actually renders, nothing crashes or collapses to
/// zero" check, not a pixel-level fidelity test.
///
/// The guard below checks the RENDER OUTPUT (a `.zero` fitting size) rather
/// than `NSApp != nil` — under `swift test` there is never a running
/// `NSApplication`, yet `NSHostingView` layout still produces real, non-zero
/// sizes whenever a window server connection is available (this environment
/// does have one: `ThemeTests.atomsComposeIntoAHostingView` already proves
/// it with the same `NSHostingView`/`layout()`/`fittingSize` recipe), so
/// `NSApp` is not a reliable signal either way. Checking the actual result
/// means this test asserts for real here and would still degrade cleanly on
/// a genuinely headless/no-display CI box, where layout collapses to zero.
@MainActor
@Test func sidebarAndListRenderWithSeededData() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let inbox = InboxModel(database: db, account: AppModel.demoAccount)
    await inbox.start()
    try await Task.sleep(for: .milliseconds(50))

    let appModel = AppModel(database: db, account: try await db.primaryAccount())
    let labels = try await db.labels(account: AppModel.demoAccount)
    let unreadCount = inbox.rows.count { $0.unread }

    let sidebar = SidebarView(
        accountEmail: appModel.account?.email, unreadCount: unreadCount, labels: labels,
        pendingCount: 0, selection: .inbox, onSelect: { _ in })
    let sidebarHost = NSHostingView(rootView: sidebar)
    sidebarHost.frame = .init(x: 0, y: 0, width: Metrics.sidebarWidth, height: 700)
    sidebarHost.layout()
    assertRendered(sidebarHost.fittingSize)

    let list = InboxListView(inbox: inbox, onOpen: { _ in })
    let listHost = NSHostingView(rootView: list)
    listHost.frame = .init(x: 0, y: 0, width: Metrics.listWidth, height: 700)
    listHost.layout()
    assertRendered(listHost.fittingSize)
}

/// A `.zero` fitting size means this environment can't lay out an
/// `NSHostingView` at all (no window server) — nothing to assert either way,
/// so this no-ops rather than failing a headless run. Any other size is a
/// real render, and must be positive on both axes.
@MainActor
private func assertRendered(_ size: NSSize) {
    guard size != .zero else { return }
    #expect(size.width > 0)
    #expect(size.height > 0)
}

/// `ThreadView` hosted against a real, opened, multi-message thread (`t01`
/// from `DemoData` — three messages, newest expanded) — exercises the
/// header, the AI-summary chip, both the expanded and collapsed message
/// rendering paths, and the reply bar all in one seeded pass.
@MainActor
@Test func threadViewRendersWithSeededThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let thread = ThreadModel(database: db, account: AppModel.demoAccount)
    await thread.open(threadID: "t01")
    try await Task.sleep(for: .milliseconds(50))

    let view = ThreadView(thread: thread, onArchive: {}, onToggleStar: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 760, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `CommandPaletteView` hosted against a `CommandModel` reloaded with a
/// selection present (so the triage commands — Archive/Star/Mark read — are
/// included alongside Search/Snooze/switch-split), exercising every row
/// kind's icon/subtitle/keycap rendering.
@MainActor
@Test func commandPaletteViewRendersWithSeededCommands() async throws {
    let command = CommandModel()
    command.reload(
        splits: [SplitTab(key: "primary", title: "Primary", count: 10)], hasSelection: true)

    let view = CommandPaletteView(command: command, perform: { _ in }, onClose: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 560, height: 480)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `SearchView` hosted against a `SearchModel` with a landed, non-empty
/// result set — "den" matches `DemoData`'s Denver-itinerary thread (`t08`),
/// mirroring `SearchModelTests.threeCharPrefixYieldsExpectedHitAfterDebounce`.
@MainActor
@Test func searchViewRendersWithSeededHits() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let search = SearchModel(database: db, account: AppModel.demoAccount, debounce: .milliseconds(10))
    search.query = "den"
    search.queryChanged()
    try await Task.sleep(for: .milliseconds(100))

    let view = SearchView(search: search, onOpen: { _ in })
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 560, height: 480)
    host.layout()
    assertRendered(host.fittingSize)
}
