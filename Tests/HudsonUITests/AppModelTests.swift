import Store
import Testing
@testable import HudsonUI

// MARK: - needsOnboarding (Task 4: first-launch gate)

/// The exact formula `RootView` gates on: no connected account AND not the
/// `--demo` path. A fresh install (no account, not demo) must signal
/// onboarding.
@MainActor
@Test func needsOnboardingIsTrueWithNoAccountAndNotDemo() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)

    #expect(model.needsOnboarding)
    #expect(!model.isDemo)
}

/// A returning user (an account is already connected) skips onboarding
/// entirely, regardless of `isDemo`.
@MainActor
@Test func needsOnboardingIsFalseOnceAnAccountIsConnected() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())

    #expect(!model.needsOnboarding)
}

/// `--demo` bypasses onboarding even in the (never-should-happen-in-practice)
/// case of no seeded account — `isDemo` alone is enough to skip the gate.
@MainActor
@Test func needsOnboardingIsFalseUnderDemoEvenWithoutAnAccount() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil, isDemo: true)

    #expect(model.isDemo)
    #expect(!model.needsOnboarding)
}

/// `AppModel.demo()` itself always lands on the non-onboarding path — it
/// seeds an account AND sets `isDemo`, doubly bypassing the gate.
@MainActor
@Test func demoAppModelNeverNeedsOnboarding() async throws {
    let model = try await AppModel.demo()

    #expect(model.isDemo)
    #expect(!model.needsOnboarding)
}

// MARK: - Navigation

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

/// The sidebar "Inbox" badge counts unread across the WHOLE mailbox and does
/// not change when the inbox list switches split tabs (the fast-follow fix —
/// it used to be derived from `inbox.rows`, which is scoped to the active split).
@MainActor
@Test func totalUnreadIsMailboxWideAndConstantAcrossSplitSwitches() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    try await Task.sleep(for: .milliseconds(100))

    let mailboxWideUnread = try await db
        .inboxThreads(account: AppModel.demoAccount, split: nil, limit: 500)
        .count { $0.unread }
    #expect(mailboxWideUnread > 0)
    #expect(model.totalUnread == mailboxWideUnread)

    // Narrowing the inbox list to one split must leave the badge unchanged.
    model.inbox.activeSplit = "important"
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.totalUnread == mailboxWideUnread)
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

/// The stale-hits regression (whole-branch review): after a search leaves
/// real results, closing and REOPENING the search overlay must show an empty
/// field with NO leftover results — `AppModel` resets the query directly, so
/// it must clear `hits` too (via `SearchModel.reset()`), not just the text.
@MainActor
@Test func reopeningSearchClearsPreviousQuerysHits() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    try await Task.sleep(for: .milliseconds(50))

    // Open search, run a real query, let results land. AppModel builds the
    // SearchModel with the production 150ms debounce (not injectable here), so
    // wait comfortably past it before asserting the precondition holds.
    model.toggleSearch()
    model.search.query = "denver"
    model.search.queryChanged()
    try await Task.sleep(for: .milliseconds(300))
    #expect(!model.search.hits.isEmpty)  // precondition: a prior search left results

    model.toggleSearch()  // close
    model.toggleSearch()  // reopen — must be a clean slate

    #expect(model.search.query.isEmpty)
    #expect(model.search.hits.isEmpty)
    #expect(!model.search.isSearching)
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

// MARK: - Compose / reply (Task 4: ⌘N and the reply bar both funnel through here)

/// `composeNew()` resets the shared `composer` to a blank draft and shows
/// the sheet — the ⌘N path.
@MainActor
@Test func composeNewStartsBlankDraftAndShowsComposer() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.composer.to = "leftover@example.com"  // simulate a stale draft left over from earlier

    model.composeNew()

    #expect(model.isComposerVisible)
    #expect(model.composer.to.isEmpty)  // startNew() cleared it
    #expect(model.composer.mode == .new)
}

/// `replyToOpenThread()` prefills the composer from the SELECTED thread
/// (`inbox.selectedThreadID` — the same id `openThread(_:)` sets) and only
/// shows the sheet once that prefill has actually landed.
@MainActor
@Test func replyToOpenThreadPrefillsFromSelectedThreadAndShowsComposer() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    model.openThread("t01")
    model.replyToOpenThread()

    // `replyToOpenThread` builds the reply scaffold asynchronously (ReplyBuilder
    // reads the thread) and only then shows the sheet — poll for that rather
    // than guessing a fixed sleep (the flake this replaces).
    for _ in 0..<80 where !model.isComposerVisible {
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(model.isComposerVisible)
    guard case .reply(let threadID) = model.composer.mode else {
        Issue.record("expected reply mode after replyToOpenThread")
        return
    }
    #expect(threadID == "t01")
    #expect(model.composer.subject == "Re: Dinner Friday?")
}

/// Nothing selected — a defensive no-op, never shows an untethered sheet.
@MainActor
@Test func replyToOpenThreadWithNoSelectionDoesNothing() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)

    model.replyToOpenThread()

    #expect(!model.isComposerVisible)
}

/// `AppModel` wires `composer.onClose` (fired by `ComposerModel.send()`
/// synchronously right after a SUCCESSFUL enqueue, see its doc comment) to
/// dismiss the sheet — the fix for `ComposerView`'s own "open question for
/// Task 4" doc comment (the undo toast then has to live at `RootView`
/// level to survive this dismissal — see `RootView.sentUndoToast`).
@MainActor
@Test func composerOnCloseDismissesTheSheet() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.composeNew()
    #expect(model.isComposerVisible)

    model.composer.onClose?()

    #expect(!model.isComposerVisible)
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
@Test func applyComposeNewOpensComposer() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    model.apply(.composeNew)
    #expect(model.isComposerVisible)
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

/// Auto-sync only starts with an account, and is idempotent (one loop, not one
/// per call). Uses an injected stack factory so the test never touches the
/// real Keychain or network.
@MainActor
@Test func startAutoSyncGuardsOnAccountAndIsIdempotent() async throws {
    // No account -> the guard returns before starting any loop.
    let noAccount = AppModel(database: try HudsonDatabase.inMemory(), account: nil)
    noAccount.startAutoSync(makeStack: { nil })
    #expect(noAccount.isAutoSyncActive == false)

    // With an account -> starts once; a second call is a no-op, not a 2nd loop.
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let model = AppModel(database: db, account: try await db.primaryAccount())
    model.startAutoSync(interval: .seconds(3600), makeStack: { nil })
    #expect(model.isAutoSyncActive == true)
    model.startAutoSync(makeStack: { nil })  // idempotent
    #expect(model.isAutoSyncActive == true)
}

/// When the composer is visible, keyboard routing switches to the `.composer`
/// context (so triage letters don't eat what you're typing).
@MainActor
@Test func keyboardContextIsComposerWhenComposerVisible() {
    let db = try! HudsonDatabase.inMemory()
    let model = AppModel(database: db, account: nil)
    #expect(model.keyboardContext == .list)
    model.isComposerVisible = true
    #expect(model.keyboardContext == .composer)
}
