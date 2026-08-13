import Foundation
import GmailKit
import Store
import Synchronization
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

    // `openThread` sets `selectedThreadID` synchronously but `ThreadModel`
    // loads the thread asynchronously — poll for the subject to land rather
    // than guessing a fixed sleep (the 50ms flake this replaces).
    for _ in 0..<80 where model.thread.subject.isEmpty {
        try await Task.sleep(for: .milliseconds(25))
    }

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
    // Poll rather than sleep past the debounce: a flat 300ms loses under
    // full-suite load, and this precondition failing reads as a bug in the
    // reset path it is only setting up for.
    try await waitUntil { !model.search.isSearching && !model.search.hits.isEmpty }
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
    try await waitUntil { model.inbox.rows.contains { $0.threadID == "t02" } }
    model.inbox.selectedThreadID = "t02"
    model.isPaletteVisible = true

    model.perform(Command(id: "archive", title: "Archive", subtitle: nil, keys: [], kind: .archive))
    // The archive is optimistic but still routed through Store + a re-emit.
    try await waitUntil { !model.inbox.rows.contains { $0.threadID == "t02" } }

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
    // `.selectNext` can only advance once the inbox observation has emitted.
    try await waitUntil { !model.inbox.rows.isEmpty }

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
    try await waitUntil { !model.inbox.rows.isEmpty }
    model.inbox.selectedThreadID = "t01"

    model.apply(.openSelected)
    try await waitUntil { !model.thread.subject.isEmpty }

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

// MARK: - hydrateBody wiring (reading-pane on-demand hydration's Keychain seam)

/// A `TokenStore` double that records every `clientSecret` lookup —
/// otherwise behaves exactly like `InMemoryTokenStore` (delegates to one
/// internally). No secret is ever saved for any account, so every lookup
/// legitimately returns `nil` — `SyncBootstrap.makeHydrator` then bails out
/// (its own documented "no stored credentials" contract) well before it
/// would ever attempt a real network call. `Synchronization.Mutex` (not a
/// plain array) because `clientSecret` is called from `LazyHydrator`, an
/// actor, so this double must itself be safe to call from any isolation
/// domain — matches `InMemoryTokenStore`'s own use of `Mutex`.
private final class RecordingTokenStore: TokenStore {
    private let inner = InMemoryTokenStore()
    private let calls = Mutex<[String]>([])

    var clientSecretCalls: [String] { calls.withLock { $0 } }

    func saveTokens(_ tokens: TokenSet, account: String) throws {
        try inner.saveTokens(tokens, account: account)
    }
    func tokens(account: String) throws -> TokenSet? { try inner.tokens(account: account) }
    func saveClientSecret(_ secret: String, account: String) throws {
        try inner.saveClientSecret(secret, account: account)
    }
    func clientSecret(account: String) throws -> String? {
        calls.withLock { $0.append(account) }
        return try inner.clientSecret(account: account)
    }
    func deleteAll(account: String) throws { try inner.deleteAll(account: account) }
}

/// The regression this guards against: `AppModel.makeHydrateBody` used to
/// ignore the initializer's injectable `tokenStore` entirely, always
/// defaulting `SyncBootstrap.makeHydrator`'s own `store:` parameter to a
/// FRESH `KeychainTokenStore()` — so every non-nil-account `AppModel`
/// construction performed an unconditional, real Keychain lookup at INIT
/// time regardless of what was injected (CI must never touch the real
/// Keychain, spec §6.3). Two things must now hold: (1) construction alone
/// makes NO `clientSecret` lookup at all — the hydrator's stack is built
/// lazily, on the FIRST on-demand fetch a reading pane actually triggers,
/// not on every `AppModel` construction (mirrors `ComposerModel
/// .makeService` deferring to send()-time; see `LazyHydrator`'s doc
/// comment) — and (2) when a fetch IS triggered, it reads through THIS
/// injected store, never a fresh default.
@MainActor
@Test func hydrateBodyIsBuiltLazilyFromTheInjectedTokenStoreNotARealKeychainAtInit() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "you@hudson.app"
    try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: .now)
    _ = try await db.applySnapshot(
        MessageSnapshot(
            id: "tk-m0", threadID: "tk", historyID: 1, internalDate: 1000,
            fromLine: "Ada Lovelace <ada@example.com>", toLine: email,
            subject: "Not hydrated yet", snippet: "sn", labelIDs: ["INBOX"]),
        account: email)
    // Deliberately no `saveBody` — a body-less row, exactly the shape that
    // drives `ThreadModel`'s on-demand `hydrateBody` fallback.

    let recordingStore = RecordingTokenStore()
    let account = try await db.account(email: email)
    let model = AppModel(database: db, account: account, tokenStore: recordingStore)

    // (1) Construction alone must never touch the token store.
    #expect(recordingStore.clientSecretCalls.isEmpty)

    // (2) Opening the thread auto-expands its sole (newest) message, which
    // has no local body — driving `ThreadModel` to fall back to
    // `hydrateBody`, which must now read through `recordingStore`.
    model.openThread("tk")
    for _ in 0..<80 where recordingStore.clientSecretCalls.isEmpty {
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(recordingStore.clientSecretCalls == [email])
    // No secret was ever saved, so the hydrator stack never actually
    // builds — the message legitimately stays uncached, exactly the
    // "no stored credentials" contract `ThreadModelTests`'
    // `nilHydrateBodyLeavesABodylessMessageUncached` already covers for a
    // `nil` hydrateBody.
    #expect(model.thread.messages.first?.bodyText == nil)
}

// MARK: - disconnectAccount() — "Disconnect account" (Task 5)

/// The full disconnect: the Keychain half (`tokenStore.deleteAll`, verified
/// behaviorally through an injected `InMemoryTokenStore` since production
/// never touches the real Keychain in tests) AND the Store half
/// (`database.deleteAccount`), plus the visible effect both exist for —
/// `needsOnboarding` flipping `true` so `RootView`'s reverse gate can bring
/// `OnboardingView` back. A second account's tokens are seeded too, to prove
/// `deleteAll` runs against the RIGHT email only (mirrors
/// `TokenStoreTests.deleteAllRemovesEverythingForOneAccountOnly`).
@MainActor
@Test func disconnectAccountClearsTokensRemovesTheAccountRowAndFlipsNeedsOnboarding() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "cid", consentedAt: Date())
    let account = try await db.account(email: "a@b.com")
    let tokenStore = InMemoryTokenStore()
    let tokens = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture)
    try tokenStore.saveTokens(tokens, account: "a@b.com")
    try tokenStore.saveTokens(tokens, account: "other@b.com")  // must survive
    let model = AppModel(database: db, account: account, tokenStore: tokenStore)
    #expect(!model.needsOnboarding)  // precondition: starts connected

    await model.disconnectAccount()

    #expect(model.account == nil)
    #expect(model.needsOnboarding)
    #expect(try tokenStore.tokens(account: "a@b.com") == nil)
    #expect(try tokenStore.tokens(account: "other@b.com") != nil)  // untouched
    #expect(try await db.account(email: "a@b.com") == nil)
}

/// No account connected at all — a defensive no-op, never touches the token
/// store or crashes (mirrors `syncNow()`'s own "guard on account" posture).
@MainActor
@Test func disconnectAccountWithNoAccountIsANoOp() async throws {
    let db = try HudsonDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let model = AppModel(database: db, account: nil, tokenStore: tokenStore)

    await model.disconnectAccount()

    #expect(model.account == nil)
}

/// A `TokenStore` double whose `deleteAll` always throws — stands in for a
/// real Keychain failure (signing-identity drift on the ACL-bound items;
/// see `KeychainTokenStore`'s doc comment) without ever touching the real
/// Keychain from a test.
private struct FailingTokenStore: TokenStore {
    struct Failure: Error {}
    func saveTokens(_ tokens: TokenSet, account: String) throws {}
    func tokens(account: String) throws -> TokenSet? { nil }
    func saveClientSecret(_ secret: String, account: String) throws {}
    func clientSecret(account: String) throws -> String? { nil }
    func deleteAll(account: String) throws { throw Failure() }
}

/// If the Keychain half throws, `disconnectAccount()` must NOT silently
/// report success: `account` stays set (so `needsOnboarding` stays `false`
/// and Settings' "Disconnect" survives to retry) and a `syncBanner` surfaces
/// the failure — this is the regression test for the bug where both deletes
/// were swallowed with bare `try?` and the account was cleared regardless.
/// The Store half never runs (the `accounts` row survives untouched) since
/// the Keychain half runs first and failed.
@MainActor
@Test func disconnectAccountSurfacesABannerAndKeepsTheAccountWhenTheKeychainDeleteFails() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "cid", consentedAt: Date())
    let account = try await db.account(email: "a@b.com")
    let model = AppModel(database: db, account: account, tokenStore: FailingTokenStore())

    await model.disconnectAccount()

    #expect(model.account != nil)
    #expect(!model.needsOnboarding)
    #expect(model.syncBanner != nil)
    #expect(try await db.account(email: "a@b.com") != nil)  // Store half never ran
}

/// If the Store half throws, `disconnectAccount()` must ALSO not silently
/// report success — even though the Keychain half already succeeded (it
/// runs first; see `disconnectAccount()`'s doc comment on the ordering).
/// `account` stays set so "Disconnect" survives to retry; a retry's Keychain
/// step is then a no-op (already empty) and only the Store half still needs
/// to land. There's no Store-protocol seam to inject a throwing double, so
/// this forces a genuine GRDB failure by dropping the `accounts` table out
/// from under `database.deleteAccount` — safe because no other table has an
/// FK on `accounts` (see `AccountStore.deleteAccount`'s doc comment), so it
/// can't cascade-break the other queries `AppModel`'s init already kicked off.
@MainActor
@Test func disconnectAccountSurfacesABannerAndKeepsTheAccountWhenTheStoreDeleteFails() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "cid", consentedAt: Date())
    let account = try await db.account(email: "a@b.com")
    let tokenStore = InMemoryTokenStore()
    let tokens = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture)
    try tokenStore.saveTokens(tokens, account: "a@b.com")
    let model = AppModel(database: db, account: account, tokenStore: tokenStore)
    try await db.writer.write { db in try db.execute(sql: "DROP TABLE accounts") }

    await model.disconnectAccount()

    #expect(model.account != nil)
    #expect(!model.needsOnboarding)
    #expect(model.syncBanner != nil)
    #expect(try tokenStore.tokens(account: "a@b.com") == nil)  // Keychain half DID run
}
