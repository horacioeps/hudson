import Store
import Testing
@testable import HudsonUI

/// `openThread` both selects the row in `inbox` and loads it into `thread` —
/// the two effects `InboxListView.onOpen`/`SearchView.onOpen` both rely on.
@MainActor
@Test func openThreadSelectsInboxRowAndLoadsThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    try await Task.sleep(for: .milliseconds(50))

    model.openThread("t01")
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.inbox.selectedThreadID == "t01")
    #expect(model.thread.subject == "Re: Dinner Friday?")
}

// MARK: - Palette / search presentation

@MainActor
@Test func togglePaletteOpensReloadsCommandsAndClosesSearch() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    try await Task.sleep(for: .milliseconds(50))
    model.isSearchVisible = true

    model.togglePalette()

    #expect(model.isPaletteVisible)
    #expect(!model.isSearchVisible)
    #expect(!model.command.results.isEmpty)  // `reload()` ran against the live split tabs

    model.togglePalette()
    #expect(!model.isPaletteVisible)
}

@MainActor
@Test func toggleSearchOpensClearsQueryAndClosesPalette() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.isPaletteVisible = true
    model.search.query = "stale"

    model.toggleSearch()

    #expect(model.isSearchVisible)
    #expect(!model.isPaletteVisible)
    #expect(model.search.query.isEmpty)
}

// MARK: - perform(_:) — palette command dispatch

@MainActor
@Test func performArchiveEnqueuesTriageAndClosesPalette() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    try await Task.sleep(for: .milliseconds(50))
    model.inbox.selectedThreadID = "t02"
    model.isPaletteVisible = true

    model.perform(Command(id: "archive", title: "Archive", subtitle: nil, keys: [], kind: .archive))
    try await Task.sleep(for: .milliseconds(50))

    #expect(!model.isPaletteVisible)
    #expect(model.inbox.rows.contains { $0.threadID == "t02" } == false)
}

@MainActor
@Test func performOpenSearchShowsSearchAndClosesPalette() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.isPaletteVisible = true
    model.search.query = "stale"

    model.perform(Command(id: "openSearch", title: "Search", subtitle: nil, keys: [], kind: .openSearch))

    #expect(model.isSearchVisible)
    #expect(!model.isPaletteVisible)
    #expect(model.search.query.isEmpty)
}

@MainActor
@Test func performSwitchSplitUpdatesActiveSplitAndClosesPalette() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.isPaletteVisible = true

    model.perform(
        Command(
            id: "switchSplit.important", title: "Switch to Important", subtitle: nil, keys: [],
            kind: .switchSplit("important")))

    #expect(model.inbox.activeSplit == "important")
    #expect(!model.isPaletteVisible)
}

/// Snooze/moveToSplit are M6 placeholders — `perform` must still close the
/// palette even though the action itself is a deliberate no-op.
@MainActor
@Test func performSnoozeIsANoOpButStillClosesPalette() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.isPaletteVisible = true

    model.perform(Command(id: "snooze", title: "Snooze", subtitle: "Coming soon", keys: [], kind: .snooze))

    #expect(!model.isPaletteVisible)
}

// MARK: - Keyboard routing seam (`keyboardContext`/`apply(_:)` — see `KeyboardMapTests` for `KeyRouter` itself)

@MainActor
@Test func keyboardContextTracksWhichOverlayIsVisible() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    #expect(model.keyboardContext == .list)

    model.isPaletteVisible = true
    #expect(model.keyboardContext == .palette)

    model.isPaletteVisible = false
    model.isSearchVisible = true
    #expect(model.keyboardContext == .search)
}

@MainActor
@Test func applySelectNextAdvancesInboxSelection() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    try await Task.sleep(for: .milliseconds(50))

    model.apply(.selectNext)
    #expect(model.inbox.selectedThreadID != nil)
}

@MainActor
@Test func applyTogglePaletteOpensIt() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.apply(.togglePalette)
    #expect(model.isPaletteVisible)
}

@MainActor
@Test func applyOpenSelectedLoadsTheSelectedThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    try await Task.sleep(for: .milliseconds(50))
    model.inbox.selectedThreadID = "t01"

    model.apply(.openSelected)
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.thread.subject == "Re: Dinner Friday?")
}

// MARK: - syncNow() — best-effort, never crashes, never blocks

/// No account connected at all (the very first launch) — `syncNow()` must
/// surface the "connect an account" banner and never touch the Keychain
/// (the guard fails before `SyncBootstrap.makeStack` is ever called).
@MainActor
@Test func syncNowWithNoAccountSurfacesConnectBanner() async {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)

    await model.syncNow()

    #expect(model.syncBanner == "Connect an account in Terminal: `hudson auth`")
    #expect(!model.isSyncing)
}
