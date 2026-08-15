import Foundation
import GmailKit
import Store
import SyncEngine

/// The root of the app's object graph. Owns the open database, the active
/// account, and every child view model (`inbox`/`thread`/`command`/
/// `search`/`composer`), plus the app-level presentation state (which
/// overlay is showing) and keyboard routing (`apply(_:)`, driven by
/// `KeyboardMonitor`).
/// `@MainActor` because every view model in Hudson is main-actor — SwiftUI
/// reads them on the main thread and Store access is via async APIs, so
/// nothing here ever blocks a cooperative-pool thread.
@MainActor
@Observable
public final class AppModel {
    public let database: HudsonDatabase
    public private(set) var account: AccountRecord?

    /// Where Gmail OAuth tokens + the BYO client secret live — injected so
    /// `disconnectAccount()` (Task 5's "Disconnect account") is testable
    /// without ever touching the real Keychain, mirroring how
    /// `SettingsModel` injects `keyStore`. `KeychainTokenStore` in
    /// production; an `InMemoryTokenStore` in tests.
    private let tokenStore: any TokenStore

    /// Whether this instance is the `--demo`/`HUDSON_DEMO=1` synthetic
    /// mailbox (`AppModel.demo()`) rather than a real one. Only `demo()`
    /// sets this `true` — every other initializer defaults it `false`. Used
    /// solely by `needsOnboarding` below; nothing else branches on it.
    public let isDemo: Bool

    /// `RootView`'s first-launch gate (Task 4): `true` iff there is no
    /// connected account AND this isn't the demo mailbox. A fresh install
    /// (no account, not demo) must see `OnboardingView`, never an empty
    /// three-pane mailbox; `--demo` always seeds its own account (see
    /// `DemoData.seed`) but ANDs in `!isDemo` too, so the gate can never
    /// fire for it even in the degenerate case of a corrupted/pre-seed demo
    /// database with no account yet.
    public var needsOnboarding: Bool { account == nil && !isDemo }

    public let inbox: InboxModel
    public let thread: ThreadModel
    public let command: CommandModel
    public let search: SearchModel
    public let settings: SettingsModel

    /// Whether the Settings sheet (AI setup) is showing.
    public var isSettingsVisible = false
    public let composer: ComposerModel

    /// The Summarize chip's view model for the OPEN thread. Reset on every
    /// `openThread` so it never carries one thread's summary over to another,
    /// and driven ONLY by `summarizeOpenThread()` — the explicit tap. Per
    /// Privacy #1 it never runs on its own (no summarize-on-open).
    public let summary: SummaryModel

    /// The sidebar's "LABELS" section — a one-shot read at launch (Store has
    /// no `observeLabels` twin the way inbox rows/split rules do, and this
    /// milestone ships no label-management UI that would need it to be
    /// reactive), refreshed again after `syncNow()` picks up new labels.
    public private(set) var labels: [LabelRecord] = []

    /// Rows currently sitting in `mutation_queue`, waiting to reach Gmail —
    /// backs the sidebar footer's "N pending" / "All synced" text.
    public private(set) var pendingCount: Int = 0
    private var pendingCountTask: Task<Void, Never>?

    /// Unread threads across the WHOLE inbox — backs the sidebar's "Inbox"
    /// badge. Observed independently of `inbox` (whose rows are scoped to the
    /// active split), so the badge shows the mailbox total and stays put when
    /// the user switches split tabs.
    public private(set) var totalUnread: Int = 0
    private var unreadCountTask: Task<Void, Never>?

    /// The background auto-sync loop (see `startAutoSync`). Kept so it can be
    /// cancelled in `deinit` and so `startAutoSync` is idempotent.
    private var autoSyncTask: Task<Void, Never>?
    private var backfillProgressTask: Task<Void, Never>?

    /// Whether the ⌘K command palette overlay is showing.
    public var isPaletteVisible = false
    /// Whether the ⌘F/`/` search overlay is showing.
    public var isSearchVisible = false
    /// Whether the compose sheet (`ComposerView`, bound to `composer`) is
    /// showing — opened by `composeNew()`/`replyToOpenThread()`, and closed
    /// either by the sheet's own Cancel/Esc (`RootView` sets this back to
    /// `false` directly) or by a SUCCESSFUL send, via `composer.onClose`
    /// (wired in both initializers below) — see `wireComposerDismissal`.
    public var isComposerVisible = false

    /// Which sidebar folder is selected — drives the sidebar highlight and the
    /// inbox list's `mailbox`. `RootView` reads this for `SidebarView(selection:)`.
    public private(set) var sidebarSelection: SidebarView.Selection = .inbox

    /// A user-visible strip for app-level sync state (offline, no account
    /// connected, a failed pass) — `nil` when there's nothing to show.
    /// Never blocks reading/triage: this is purely informational.
    public private(set) var syncBanner: String?
    /// True while a `syncNow()` pass is in flight — guards against
    /// overlapping passes from a double-tap of whatever future UI calls it.
    public private(set) var isSyncing = false

    /// True while the initial backfill / body-hydration is still catching up.
    /// Drives the footer's "Getting your mail…" line and the inbox list's
    /// loading empty state, so a fresh account is never told "All synced"
    /// while its mail is still arriving.
    ///
    /// **Seeded SYNCHRONOUSLY in both initializers**, from the persisted
    /// `backfill_state` already sitting in the `AccountRecord` we were handed —
    /// no network, no Keychain, no `await`. That ordering is the whole fix for
    /// the original bug: this used to be declared `false` and first assigned
    /// only after the opening `syncOnce()` returned, so for the entire first
    /// pass on a fresh account (hundreds of `messages.get` calls) the footer
    /// read "All synced" and the empty inbox read "No messages here". Every
    /// async path below may now only ever REFINE this value; none of them is
    /// the first thing to set it, so the very first frame is already honest.
    public private(set) var isCatchingUp: Bool

    /// Set when a sync pass throws, cleared when one succeeds. Distinguishes
    /// "still downloading" from "cannot reach Gmail" in the footer — without
    /// it, an offline first launch shows a progress line (or a part-filled
    /// bar) frozen forever with no explanation, since the auto-sync loop is
    /// deliberately silent about failures (it never touches `syncBanner`).
    public private(set) var isSyncStalled = false

    /// Live backfill progress for the first-launch indicator, or `nil` when
    /// there is nothing to report. See `BackfillProgress` in Store.
    public private(set) var backfillProgress: BackfillProgress?

    /// The determinate fraction to render, or `nil` for "total not known yet"
    /// (before the first list page returns) and for any run that is NOT a
    /// first download — re-listing mail already on disk is not progress the
    /// user can see, so it gets the status line and no bar.
    ///
    /// Ratcheted: never decreases within a run, so a message deleted mid-pass
    /// (which shrinks the live count) can't rewind the bar. Capped below 1.0
    /// while running, because the denominator is Gmail's own approximation and
    /// a determinate bar must never claim "almost done" on a number we know is
    /// inexact. Completion is signalled by `backfill_state`, never by this
    /// value reaching a threshold.
    public private(set) var backfillFraction: Double?

    /// Hard ceiling for a running bar — see `backfillFraction`.
    static let backfillFractionCeiling = 0.95

    private static let connectAccountBannerText = "Connect an account in Terminal: `hudson auth`"

    /// Opens the store at `databaseURL`, loads the primary account, and
    /// builds every child model. Never touches the Keychain or the network
    /// — the app is read-and-triage until the user explicitly triggers
    /// `syncNow()`.
    public init(databaseURL: URL, tokenStore: (any TokenStore)? = nil) async throws {
        let database = try HudsonDatabase.open(at: databaseURL)
        self.database = database
        let account = try await database.primaryAccount()
        self.account = account
        self.isDemo = false
        self.isCatchingUp = Self.seedCatchingUp(account: account, isDemo: false)
        self.tokenStore = tokenStore ?? KeychainTokenStore()
        let email = Self.accountEmail(account)
        self.inbox = InboxModel(database: database, account: email)
        self.thread = ThreadModel(
            database: database, account: email,
            hydrateBody: Self.makeHydrateBody(database: database, account: account, store: self.tokenStore))
        self.command = CommandModel()
        self.search = SearchModel(database: database, account: email)
        self.settings = SettingsModel(database: database, account: email)
        self.composer = ComposerModel(database: database, account: account)
        self.summary = SummaryModel(database: database, account: email)
        await inbox.start()
        await refreshLabels()
        subscribeToPendingCount()
        subscribeToUnreadCount()
        wireComposerDismissal()
    }

    /// Direct-injection initializer for tests and previews (seeded
    /// in-memory DB). `inbox.start()`/label/pending-count loading still
    /// happen — just from an unstructured `Task` rather than awaited here,
    /// since this initializer is (deliberately, to match callers like
    /// `demo()` and existing tests) synchronous. Matches `InboxModel.start()`
    /// et al.'s own contract: launching the subscription doesn't wait for
    /// its first emission to land. `isDemo` defaults `false` — only `demo()`
    /// passes `true`; every other caller (tests, `RootView`'s post-onboarding
    /// rebuild) gets the real, non-demo `needsOnboarding` semantics.
    public init(
        database: HudsonDatabase, account: AccountRecord?, isDemo: Bool = false,
        tokenStore: (any TokenStore)? = nil
    ) {
        self.database = database
        self.account = account
        self.isDemo = isDemo
        self.isCatchingUp = Self.seedCatchingUp(account: account, isDemo: isDemo)
        self.tokenStore = tokenStore ?? KeychainTokenStore()
        let email = Self.accountEmail(account)
        self.inbox = InboxModel(database: database, account: email)
        self.thread = ThreadModel(
            database: database, account: email,
            hydrateBody: Self.makeHydrateBody(database: database, account: account, store: self.tokenStore))
        self.command = CommandModel()
        self.search = SearchModel(database: database, account: email)
        self.settings = SettingsModel(database: database, account: email)
        self.composer = ComposerModel(database: database, account: account)
        self.summary = SummaryModel(database: database, account: email)
        let inbox = self.inbox
        Task { await inbox.start() }
        Task { [weak self] in await self?.refreshLabels() }
        subscribeToPendingCount()
        subscribeToUnreadCount()
        wireComposerDismissal()
    }

    /// The demo mailbox's account — matches `DemoData.seed`'s default so
    /// `--demo` reads back exactly what it seeded.
    public static let demoAccount = "you@hudson.app"

    /// Opens (creating if needed) the fixed-path demo database and seeds it
    /// with `DemoData` on first open — guarded on `inboxThreads` being
    /// empty so a relaunch of `--demo`/`HUDSON_DEMO=1` never re-seeds (and
    /// never duplicates) an already-seeded demo mailbox. Used for
    /// screenshots and manual QA without ever touching a real mailbox.
    public static func demo() async throws -> AppModel {
        let url = FileManager.default.temporaryDirectory.appending(path: "hudson-demo.sqlite")
        let database = try HudsonDatabase.open(at: url)
        let existing = try await database.inboxThreads(account: demoAccount, split: nil, limit: 1)
        if existing.isEmpty {
            try await DemoData.seed(into: database, account: demoAccount)
        }
        let account = try await database.primaryAccount()
        return AppModel(database: database, account: account, isDemo: true)
    }

    /// No account yet reads back as an empty account string — every Store
    /// read the child models below make just comes back empty for it, never
    /// a crash. In practice `RootView`'s `needsOnboarding` gate (Task 4)
    /// keeps a real, non-demo launch with no account from ever mounting
    /// this shell at all (it shows `OnboardingView` instead); this stays
    /// the safe default regardless, so any direct `AppModel(database:
    /// account: nil)` construction (tests, previews) still renders cleanly
    /// (empty inbox, empty search) rather than crashing.
    private static func accountEmail(_ account: AccountRecord?) -> String {
        account?.email ?? ""
    }

    /// The synchronous, network-free opening value of `isCatchingUp`, read off
    /// the persisted `backfill_state` in the record we already hold.
    ///
    /// No account means nothing is syncing. The demo mailbox never syncs at
    /// all, so it is excluded explicitly as well as by `DemoData.seed` marking
    /// its account complete — belt and braces, since a bar that can never
    /// advance is worse than no bar.
    ///
    /// A missing/unknown state is treated as "complete" (not catching up):
    /// this runs on every launch, and the failure that matters is claiming
    /// progress that will never arrive, not briefly under-reporting it.
    static func seedCatchingUp(account: AccountRecord?, isDemo: Bool) -> Bool {
        guard !isDemo, let account else { return false }
        return account.backfillState != "complete"
    }

    /// `ThreadModel`'s on-demand body-fetch closure (Task: reading-pane
    /// on-demand hydration) — thin passthrough to a `LazyHydrator` (below),
    /// which defers `SyncBootstrap.makeHydrator`'s actual Keychain ->
    /// OAuthClient -> GmailClient -> SyncEngine wiring (see its doc
    /// comment) to the FIRST on-demand fetch a reading pane actually
    /// triggers, rather than building it eagerly here during `AppModel`
    /// init — see `LazyHydrator`'s doc comment for why. Kept here, rather
    /// than inlined at each of the two `ThreadModel(...)` call sites
    /// above, purely to avoid repeating the `account.flatMap { ... }`
    /// unwrap twice.
    ///
    /// `store` is always THIS `AppModel`'s own resolved `tokenStore` (never
    /// a fresh default) — passing it through is what lets a test's injected
    /// `InMemoryTokenStore` actually reach the hydrator instead of a real
    /// `KeychainTokenStore()` silently taking over underneath it.
    ///
    /// `nil` account (no connected account — matches `accountEmail`'s own
    /// "no account yet" contract) means `nil` here too: there's no
    /// `AccountRecord` to build a `GmailClient` from, so on-demand
    /// hydration is simply unavailable — exactly the same "local-only"
    /// posture `SyncBootstrap.makeHydrator` already gives an account with
    /// no stored Keychain credentials (the `--demo` mailbox, or any first
    /// launch before `hudson auth`).
    private static func makeHydrateBody(
        database: HudsonDatabase, account: AccountRecord?, store: any TokenStore
    ) -> (@Sendable (String) async -> Bool)? {
        guard let account else { return nil }
        let hydrator = LazyHydrator(database: database, account: account, store: store)
        return { id in await hydrator.hydrate(id) }
    }

    /// Both subscription tasks capture `self` only weakly, so nothing here
    /// keeps `self` alive past this — matches `InboxModel`'s own `isolated
    /// deinit` (SE-0371; `pendingCountTask` is `@MainActor`-isolated
    /// storage, so a plain `nonisolated deinit` can't touch it).
    isolated deinit {
        pendingCountTask?.cancel()
        unreadCountTask?.cancel()
        autoSyncTask?.cancel()
        backfillProgressTask?.cancel()
    }

    private func subscribeToPendingCount() {
        guard let account else { return }
        let email = account.email
        let database = self.database
        pendingCountTask = Task { [weak self] in
            do {
                for try await count in database.observePendingCount(account: email) {
                    guard let self, !Task.isCancelled else { return }
                    self.pendingCount = count
                }
            } catch {
                // Matches `InboxModel`'s subscriptions: a genuine Store
                // failure here has no recovery beyond the next launch —
                // nothing user-actionable to surface differently.
            }
        }
    }

    private func subscribeToUnreadCount() {
        guard let account else { return }
        let email = account.email
        let database = self.database
        unreadCountTask = Task { [weak self] in
            do {
                for try await count in database.observeInboxUnreadCount(account: email) {
                    guard let self, !Task.isCancelled else { return }
                    self.totalUnread = count
                }
            } catch {
                // Same posture as the pending-count subscription: a genuine
                // Store failure here has no recovery beyond the next launch.
            }
        }
    }

    private func refreshLabels() async {
        guard let account else { return }
        labels = (try? await database.labels(account: account.email)) ?? []
    }

    /// Lets a successful send dismiss the compose sheet from HERE, not from
    /// the view: `ComposerModel.send()` fires `onClose?()` synchronously
    /// right after enqueueing (see its doc comment), so wiring that straight
    /// to `isComposerVisible = false` is the same "model owns the dismissal"
    /// shape `togglePalette`/`toggleSearch` already use for the other two
    /// overlays. Called once, at the end of each initializer, after every
    /// stored property (including `composer` itself) has a value — matches
    /// `subscribeToPendingCount`/`subscribeToUnreadCount`'s own established
    /// "capture self weakly once fully initialized" convention, just for a
    /// callback assignment rather than a `Task`.
    ///
    /// The compose sheet closing does NOT drop the just-sent draft's undo
    /// affordance — `ComposerModel.justSentUndoJobID` deliberately outlives
    /// `onClose` firing, so `RootView` renders that toast independently of
    /// whether the sheet itself is still mounted (see `RootView.assembled`).
    private func wireComposerDismissal() {
        composer.onClose = { [weak self] in self?.isComposerVisible = false }
    }

    // MARK: - Navigation

    /// Selects `threadID` in the inbox list and loads it into the reading
    /// pane. Synchronous (matches `InboxListView`'s `onOpen: (String) ->
    /// Void` and `SearchView`'s `onOpen`) — `thread.open` is async, so it
    /// runs in its own `Task`; `ThreadModel.open` doesn't wait for its
    /// first emission either (see its doc comment), so this doesn't need to.
    /// Maps a sidebar tap to the inbox list's folder. Sent/Starred and user
    /// labels are "threads carrying label X"; Inbox is the split view. Snoozed
    /// points at the `Hudson/Snoozed` label — empty until M6 adds snoozing.
    public func selectFolder(_ selection: SidebarView.Selection) {
        sidebarSelection = selection
        switch selection {
        case .inbox: inbox.mailbox = .inbox
        case .starred: inbox.mailbox = .label(id: "STARRED", title: "Starred")
        case .sent: inbox.mailbox = .label(id: "SENT", title: "Sent")
        case .snoozed: inbox.mailbox = .label(id: "Hudson/Snoozed", title: "Snoozed")
        case .label(let id):
            inbox.mailbox = .label(id: id, title: labels.first { $0.id == id }?.name ?? "Label")
        }
    }

    public func openThread(_ threadID: String) {
        inbox.selectedThreadID = threadID
        // Drop the previous thread's summary so the chip resets to its
        // untapped state — a summary is per-thread and must never bleed across
        // a switch. This clears local state only; it never triggers a new
        // summarize (that stays an explicit tap — Privacy #1, no auto-run).
        summary.reset()
        Task { await thread.open(threadID: threadID) }
    }

    /// Runs the Summarize chip for whichever thread is open
    /// (`inbox.selectedThreadID`, the same id the reading pane shows) —
    /// `ThreadView`'s chip funnels through here. This is the explicit user
    /// action the `.summarize` `Invocation` stands for; it egresses ONLY if
    /// the feature is opted in (the gate lives under `SummaryModel` →
    /// `AIBootstrap`/`EgressGuard`). A no-op, defensively, when nothing is
    /// selected. Synchronous like the other chrome actions: `summarize` is
    /// async, so it runs in its own `Task`.
    public func summarizeOpenThread() {
        guard let threadID = inbox.selectedThreadID else { return }
        Task { [weak self] in await self?.summary.summarize(threadID: threadID) }
    }

    // MARK: - Compose / reply (see `ComposerModel`; ⌘N and the reply bar both funnel here)

    /// Opens the compose sheet with a blank draft — the ⌘N shortcut
    /// (`KeyAction.composeNew`) funnels through here. Synchronous:
    /// `ComposerModel.startNew()` does no async work (see its doc comment),
    /// so there's nothing to await before showing the sheet.
    public func composeNew() {
        composer.startNew()
        isComposerVisible = true
    }

    /// Opens the compose sheet pre-filled as a reply to whichever thread is
    /// currently open (`inbox.selectedThreadID` — the same id `openThread(_:)`
    /// sets and `ThreadView`'s reading pane is showing) — `ThreadView`'s
    /// Reply bar funnels through here. A no-op, defensively, if nothing is
    /// selected: `RootView` only mounts the Reply bar once a thread is open,
    /// but this doesn't trust that invariant rather than risk showing an
    /// untethered sheet. `ComposerModel.startReply` is async (it reads the
    /// thread to build the real threading scaffold via `ReplyBuilder`), so
    /// the sheet is shown only AFTER it resolves — the draft is already
    /// fully prefilled the instant it appears, no empty-to-populated flash.
    public func replyToOpenThread() {
        guard let threadID = inbox.selectedThreadID else { return }
        Task { [weak self] in
            await self?.composer.startReply(threadID: threadID)
            self?.isComposerVisible = true
        }
    }

    // MARK: - Palette / search presentation

    /// Opens the palette (reloading its command list for the CURRENT split
    /// tabs/selection first) or closes it. Opening always closes search —
    /// only one overlay is ever showing at once.
    public func togglePalette() {
        if isPaletteVisible {
            isPaletteVisible = false
            return
        }
        isSearchVisible = false
        command.query = ""
        command.reload(splits: inbox.tabs, hasSelection: inbox.selectedThreadID != nil)
        isPaletteVisible = true
    }

    /// Opens the search overlay (clearing any previous query first) or
    /// closes it. Opening always closes the palette — see `togglePalette`.
    public func toggleSearch() {
        if isSearchVisible {
            isSearchVisible = false
            return
        }
        isPaletteVisible = false
        search.reset()
        isSearchVisible = true
    }

    // MARK: - Command dispatch

    /// Interprets a palette `Command`'s `kind` and performs it, then closes
    /// the palette — matches `CommandKind`'s doc comment on why this
    /// dispatch deliberately lives outside `CommandModel` itself. Triage
    /// actions are `async throws`; each runs in its own `Task` so this stays
    /// synchronous (the palette view calls it straight from a Button
    /// action) — the optimistic `enqueueMutation` overlay makes the result
    /// feel instant regardless of when the `Task` actually finishes.
    public func perform(_ entry: Command) {
        switch entry.kind {
        case .archive:
            Task { try? await self.inbox.archiveSelected() }
        case .toggleStar:
            Task { try? await self.inbox.toggleStarSelected() }
        case .toggleRead:
            Task { try? await self.inbox.toggleReadSelected() }
        case .openSearch:
            search.reset()
            isSearchVisible = true
        case .switchSplit(let key):
            inbox.activeSplit = key
        case .snooze, .moveToSplit:
            break  // Coming soon (M6) — listed in the palette but not wired yet.
        }
        isPaletteVisible = false
    }

    // MARK: - Keyboard routing (see `KeyboardMap.swift`, `KeyboardMonitor`)

    /// Which routing rules `KeyRouter.route` should apply to the next key
    /// event — derived, never stored, so it can never drift from the
    /// overlay flags that actually drive what's on screen.
    var keyboardContext: KeyboardContext {
        // The composer AND settings are text-entry modals — they take keyboard
        // priority so the list's single-letter triage shortcuts never eat
        // characters you're typing (into an email, an API key, a base URL, …).
        if isComposerVisible || isSettingsVisible { return .composer }
        if isPaletteVisible { return .palette }
        if isSearchVisible { return .search }
        return .list
    }

    /// Applies one routed `KeyAction` — the only thing `KeyboardMonitor`
    /// calls. Contains no routing decisions of its own; see `KeyRouter`.
    func apply(_ action: KeyAction) {
        switch action {
        case .moveHighlight(let offset): command.moveHighlight(by: offset)
        case .performHighlighted:
            if let highlighted = command.highlightedCommand { perform(highlighted) }
        case .closePalette: isPaletteVisible = false
        case .closeSearch: isSearchVisible = false
        case .selectNext: inbox.selectNext()
        case .selectPrevious: inbox.selectPrevious()
        case .openSelected:
            if let selectedThreadID = inbox.selectedThreadID { openThread(selectedThreadID) }
        case .archiveSelected: Task { try? await self.inbox.archiveSelected() }
        case .toggleStarSelected: Task { try? await self.inbox.toggleStarSelected() }
        case .toggleReadSelected: Task { try? await self.inbox.toggleReadSelected() }
        case .clearSelection: inbox.selectedThreadID = nil
        case .togglePalette: togglePalette()
        case .toggleSearch: toggleSearch()
        case .composeNew: composeNew()
        case .closeComposer:
            // Esc closes whichever text-entry modal is open.
            if isSettingsVisible { isSettingsVisible = false } else { isComposerVisible = false }
        }
    }

    // MARK: - Sync (mail poll/flush — machine<->Gmail direct, no server; see Privacy #1)

    /// Background auto-sync: on launch and every `interval`, quietly pull new
    /// mail (a cheap Gmail history poll, ~2 quota units) and flush queued
    /// triage/sends — so the mailbox stays live WITHOUT the user pressing "Sync
    /// now". This is NOT a Privacy-#1 departure: it fetches the user's OWN mail
    /// directly (machine <-> Gmail, no server, no middleman). Privacy #1 bans
    /// *AI-content* egress and background *AI* (no summarize-on-scroll), not
    /// being an email client. Deliberately QUIET — it never touches
    /// `isSyncing`/`syncBanner` (those are the manual button's UI feedback); a
    /// failed pass just waits for the next tick. Idempotent (guards on the
    /// task) and a no-op under `--demo`/no-creds (the stack is nil, so it
    /// returns before any network call). Started by `RootView` once the real
    /// model has loaded; cancelled in `deinit`.
    // Internal (not public): `SyncStack` is an internal UI seam, and the only
    // callers are `RootView` (same module) and tests (`@testable`).
    func startAutoSync(
        interval: Duration = .seconds(30),
        makeStack: (@Sendable () -> SyncStack?)? = nil
    ) {
        guard autoSyncTask == nil, let account else { return }
        let database = self.database
        // `makeStack` is injectable so tests stay hermetic (the default hits
        // the Keychain via `SyncBootstrap`; a test passes a fake).
        let make = makeStack ?? { SyncBootstrap.makeStack(database: database, account: account) }
        autoSyncTask = Task { [weak self] in
            // Both of these run REGARDLESS of whether a network stack can be
            // built. They are local Store reads, and hoisting them above the
            // guard is what stops a credential-less launch from latching the
            // synchronously-seeded `isCatchingUp` on forever: everything that
            // can clear it lives below, so an early `return` used to leave the
            // footer promising mail that was never coming.
            await self?.refreshHydrationBacklog()
            self?.subscribeToBackfillProgress()
            guard let stack = make() else {
                // No stored credentials (a disconnected account, or a
                // half-finished setup). Say so instead of implying a download
                // is in progress — the loop below, which is deliberately
                // silent about failures, is not going to run at all.
                self?.isCatchingUp = false
                self?.syncBanner = Self.connectAccountBannerText
                return
            }
            // Also drain the SEND queue (durable send jobs whose undo-hold has
            // elapsed) — a SEPARATE flusher from `stack.flusher` (which only
            // drains triage `mutation_queue`). Without this, a composed email
            // sits queued forever after its hold, which is exactly the
            // "said Sent but never sent" bug.
            let sendService = SendBootstrap.makeService(database: database, account: account)
            while !Task.isCancelled {
                let report = try? await stack.engine.syncOnce()
                _ = try? await stack.flusher.flushOnce()
                if let sendService {
                    _ = try? await sendService.flushOnce(now: Int64(Date().timeIntervalSince1970 * 1000))
                }
                await self?.refreshLabels()
                // Initial backfill + body hydration run in bounded per-pass
                // batches. While there's still work — the backfill isn't
                // complete, or this pass hydrated bodies (so more likely
                // remain) — loop back after a short beat so a fresh account's
                // mail fills in ~a minute instead of ~15, then relax to the
                // full interval once caught up. The same signal keeps the
                // footer honest (isCatchingUp) rather than claiming "All
                // synced" mid-hydration.
                // A THROWN pass yields nil here. It must not be read as
                // "nothing left to do": `Optional(nil) == Optional(false)` is
                // false, so the old unconditional assignment turned one
                // network blip into "All synced" AND relaxed the poll to the
                // slow interval. Now a failed pass leaves the last honest
                // value standing, says so via `isSyncStalled`, and backs off.
                // A pass takes seconds and the writes below are @MainActor
                // state. `disconnectAccount` cancels this task, but only after
                // its own awaited Store calls — so without this check an
                // in-flight pass could resume afterwards and repopulate the
                // very flags the disconnect just cleared.
                guard !Task.isCancelled else { return }
                guard let report else {
                    self?.isSyncStalled = true
                    try? await Task.sleep(for: interval)
                    continue
                }
                self?.isSyncStalled = false
                let catchingUp = !report.backfillComplete || report.bodiesHydrated > 0
                self?.isCatchingUp = catchingUp
                try? await Task.sleep(for: catchingUp ? .seconds(2) : interval)
            }
            self?.isCatchingUp = false
        }
    }

    /// Sets `isCatchingUp` when bodies still need fetching even though
    /// backfill itself has finished — the relaunch-mid-hydration case. Only
    /// ever turns the flag ON: the loop below owns turning it off, once a real
    /// pass has reported.
    private func refreshHydrationBacklog() async {
        guard let account, !isDemo else { return }
        let windowStart = Int64(
            Date().addingTimeInterval(-Double(Self.hydrationWindowDays) * 86_400)
                .timeIntervalSince1970 * 1_000)
        let pending = (try? await database.messageIDsNeedingBodies(
            account: account.email, since: windowStart, limit: 1)) ?? []
        if !pending.isEmpty { isCatchingUp = true }
    }

    /// Mirrors `SyncEngine`'s own `prefetchWindowDays` default. Hydration
    /// anchors on `now()` while backfill anchors on `consentedAt`, so these
    /// two windows are deliberately different quantities and must not be
    /// merged into one constant.
    static let hydrationWindowDays = 90

    /// Subscribes to `observeBackfillProgress` and ratchets the fraction.
    /// Started from inside `startAutoSync`'s task, so a launch with no
    /// credentials (or `--demo`) never renders a bar that could not advance.
    private func subscribeToBackfillProgress() {
        guard let account, !isDemo, backfillProgressTask == nil else { return }
        let windowStart = SyncEngine.backfillWindowStartMilliseconds(
            consentedAt: account.consentedAt, lookbackDays: Self.backfillWindowDays)
        let email = account.email
        let database = self.database
        backfillProgressTask = Task { [weak self] in
            do {
                for try await progress in database.observeBackfillProgress(
                    account: email, windowStart: windowStart) {
                    guard let self, !Task.isCancelled else { return }
                    self.applyBackfillProgress(progress)
                }
            } catch {
                // Same posture as the other Store subscriptions: a genuine
                // failure here has no recovery beyond the next launch, and the
                // synchronously-seeded `isCatchingUp` still tells the truth.
            }
        }
    }

    /// Mirrors `SyncEngine`'s own `backfillLookbackDays` default — the 90-day
    /// sync window. The progress count MUST use the same boundary the backfill
    /// lists, or numerator and denominator describe different sets.
    static let backfillWindowDays = 90

    /// Folds one observation emit into the rendered state, applying the
    /// ratchet and the ceiling. Split out from the subscription so tests can
    /// drive the exact sequence of emits that a real backfill produces.
    func applyBackfillProgress(_ progress: BackfillProgress) {
        backfillProgress = progress
        // The observation is persisted truth about backfill and outranks the
        // report-derived guess for that half. It can only turn catching-up ON
        // here; hydration (which this does not measure) owns turning it off.
        if progress.isRunning { isCatchingUp = true }

        guard progress.isRunning else {
            // Completion is state-driven. Fill the bar out ONLY if one was
            // actually being drawn, so it leaves the screen full rather than
            // stranded at the 0.95 ceiling.
            //
            // The `!= nil` test is load-bearing, not defensive: the runs that
            // deliberately get no bar — a re-list of mail already on disk, and
            // a first download whose estimate came back nil or zero — reach
            // this line too, and filling unconditionally made a full bar
            // materialize for them out of nowhere. (The previous form,
            // `backfillProgress == nil ? nil : 1.0`, could never take its nil
            // arm at all: `backfillProgress` is assigned from the non-optional
            // parameter a few lines above.)
            if backfillFraction != nil { backfillFraction = 1.0 }
            return
        }
        guard progress.isFirstDownload, let total = progress.totalEstimate, total > 0 else {
            // Either the total isn't known yet (before page one returns) or
            // this run is re-listing mail already on disk. Both render as the
            // status line with an empty track, never a moving bar.
            backfillFraction = nil
            return
        }
        let raw = Double(progress.stored) / Double(total)
        let capped = min(raw, Self.backfillFractionCeiling)
        backfillFraction = max(backfillFraction ?? 0, capped)
    }

    /// Test seam: whether the background auto-sync loop is running.
    var isAutoSyncActive: Bool { autoSyncTask != nil }

    /// Wired to the sidebar footer's "Sync now" button (`RootView` ->
    /// `SidebarView.onSyncNow`) — a MANUAL "refresh right now" override on top
    /// of the automatic `startAutoSync` loop above. Surfaces a banner on the
    /// no-account / failure paths (the auto loop stays silent).
    ///
    /// Best-effort and fully guarded: builds the network stack from the
    /// Keychain (mirrors `HudsonCLI/Runtime.bootstrap()`, via
    /// `SyncBootstrap`); if credentials are absent (the common case for
    /// `--demo` and any first launch) or anything throws, sets a
    /// user-visible banner and returns — NEVER crashes, NEVER blocks the
    /// UI. The actual poll/flush runs in its own `Task`; `syncNow()` itself
    /// returns as soon as that `Task` is launched.
    public func syncNow() async {
        guard !isSyncing else { return }
        guard let account, let stack = SyncBootstrap.makeStack(database: database, account: account) else {
            syncBanner = Self.connectAccountBannerText
            return
        }
        syncBanner = nil
        isSyncing = true
        Task { [weak self] in
            await self?.runSyncPass(stack)
        }
    }

    private func runSyncPass(_ stack: SyncStack) async {
        defer { isSyncing = false }
        do {
            _ = try await stack.engine.syncOnce()
            _ = try await stack.flusher.flushOnce()
            await refreshLabels()
            // The manual button and the background loop share one notion of
            // whether Gmail is reachable. Without this, a successful "Sync
            // now" left `isSyncStalled` set by an earlier failed background
            // pass, and the footer kept saying "Waiting for network…" —
            // outranking every other status — until the loop happened to
            // succeed on its own.
            isSyncStalled = false
        } catch {
            isSyncStalled = true
            syncBanner = "Sync failed — check your connection."
        }
    }

    // MARK: - Disconnect account (Task 5)

    /// User-visible message shown via `syncBanner` — reusing `runSyncPass`'s
    /// own banner mechanism, not a new one — when `disconnectAccount()`'s
    /// purge only PARTIALLY completes. See that method's doc comment for why
    /// a partial failure must never be reported as success.
    private static let disconnectFailedBannerText = "Couldn't disconnect — try again."

    /// "Disconnect <email>" from Settings: removes this Mac's copy of the
    /// connected account — clears its Gmail OAuth tokens + BYO client secret
    /// from the Keychain (`tokenStore.deleteAll`), deletes its `accounts` row
    /// (`database.deleteAccount`), stops the now-pointless background
    /// auto-sync loop, and clears `account`. That last write is what flips
    /// `needsOnboarding` back to `true` — `RootView`'s reverse gate (the
    /// `.onChange` mirror of Task 4's forward `.task` gate) reacts to that
    /// exact transition and brings `OnboardingView` back, so the app
    /// genuinely returns to first-launch, not just an emptied mailbox.
    ///
    /// Neither delete is `try?`'d away: a genuinely thrown error from EITHER
    /// one aborts the disconnect, surfaces `syncBanner` (mirrors
    /// `runSyncPass`'s own failure posture), and — crucially — leaves
    /// `self.account` set. `needsOnboarding` therefore stays `false` and
    /// Settings' "Disconnect" affordance stays up, so the app never lies
    /// about having forgotten an account it still has a live trace of, and
    /// the user can simply retry.
    ///
    /// The two deletes run in this order, DELIBERATELY, not concurrently:
    ///
    /// 1. Keychain (`tokenStore.deleteAll`) first. Both `TokenStore`
    ///    implementations (`InMemoryTokenStore`, `KeychainTokenStore`) treat
    ///    deleting an already-empty/missing entry as a no-op rather than an
    ///    error, so if THIS step throws, nothing has changed yet — a retry
    ///    (or simply relaunching, since the `accounts` row is still there)
    ///    starts from the exact same state.
    /// 2. The `accounts` row (`database.deleteAccount`) second, ONLY once the
    ///    Keychain half is confirmed gone. Running these in the opposite
    ///    order would risk the worse failure: the `accounts` row (the thing
    ///    that flips `needsOnboarding` and hides "Disconnect") gone while a
    ///    failed Keychain purge leaves the OAuth tokens/BYO secret orphaned —
    ///    with no UI left to retry removing them, since there's no longer a
    ///    connected account to run "Disconnect" against.
    ///
    /// If step 1 succeeds but step 2 throws, the Keychain half genuinely IS
    /// clean — only the Store half still needs to land, and a retry's step 1
    /// is then a cheap no-op.
    ///
    /// A no-op if there's no connected account to disconnect (mirrors
    /// `syncNow()`'s own "guard on account" posture) — nothing to clear, and
    /// crucially nothing that could flip `needsOnboarding` for the demo
    /// mailbox (`isDemo` alone keeps that gate shut regardless, but this
    /// guard means a stray call here never even touches the Keychain/Store
    /// for a mailbox with no real account).
    ///
    /// Deliberately does NOT touch already-synced mail (`messages`/
    /// `threads`, ...) — see `AccountStore.deleteAccount`'s doc comment.
    /// "Disconnect" forgets the CONNECTION; it isn't a full data wipe.
    public func disconnectAccount() async {
        guard let account else { return }
        let email = account.email
        syncBanner = nil

        do {
            try tokenStore.deleteAll(account: email)
        } catch {
            syncBanner = Self.disconnectFailedBannerText
            return
        }
        // Revoke this address's AI consent BEFORE deleting the account row.
        // `ai_config` has no foreign key to `accounts`, so its rows outlive
        // the delete — without this, reconnecting the same address later would
        // silently restore an `opt_in = 1` granted in a previous session, and
        // the first Summarize tap would egress against a consent the user has
        // every reason to believe they revoked.
        //
        // The ORDER matters and mirrors the Keychain-then-Store reasoning
        // above: revoking first means a failure here leaves everything intact
        // and retryable, whereas revoking last would let a crash between the
        // two writes leave `opt_in = 1` for an address the app has already
        // forgotten — precisely the resurrection this closes. Not `try?` for
        // the same reason the other two steps aren't: a partial purge must
        // never be reported as a completed disconnect.
        do {
            try await database.revokeAIOptIn(account: email)
        } catch {
            syncBanner = Self.disconnectFailedBannerText
            return
        }
        do {
            try await database.deleteAccount(email: email)
        } catch {
            syncBanner = Self.disconnectFailedBannerText
            return
        }

        autoSyncTask?.cancel()
        autoSyncTask = nil
        backfillProgressTask?.cancel()
        backfillProgressTask = nil
        backfillProgress = nil
        backfillFraction = nil
        isCatchingUp = false
        isSyncStalled = false
        self.account = nil
    }
}

/// Builds `SyncBootstrap.makeHydrator`'s Keychain -> OAuthClient ->
/// GmailClient -> SyncEngine stack lazily — on the FIRST on-demand body
/// fetch a reading pane actually triggers — rather than eagerly during
/// `AppModel` init. Building that stack performs a real, synchronous
/// token-store lookup (`store.clientSecret`, backed by the macOS Keychain
/// in production); doing that unconditionally on EVERY `AppModel`
/// construction, rather than only the comparatively rare case where a
/// reading pane actually expands a message the background hydration pass
/// hasn't reached yet, is both wasted work on every launch and, in tests,
/// a correctness bug: constructing `SyncBootstrap`'s own default
/// `KeychainTokenStore()` there — instead of deferring to whatever
/// `TokenStore` double a test injected into `AppModel` — is exactly the
/// kind of real-Keychain touch spec §6.3 forbids from CI.
///
/// Mirrors `ComposerModel.makeService`, which defers
/// `SendBootstrap.makeService`'s identical wiring from init-time to
/// send()-time (see its doc comment) — the one difference is that the
/// built stack is cached here after the first attempt (success OR a
/// definitive "no stored credentials"), since `SyncEngine.hydrate
/// (messageID:)` is just as safe to reuse across on-demand fetches as
/// `SyncBootstrap.makeStack`'s `engine` already is across
/// `AppModel.syncNow()`/`startAutoSync` passes — there's no per-call
/// reason (unlike `ComposerModel.send()`, where re-reading credentials
/// fresh each send is the point) to rebuild it on every single expand.
///
/// An `actor` — not a plain class — because the closure `makeHydrateBody`
/// returns is typed `@Sendable` (`ThreadModel.hydrateBody`'s contract) and
/// its `hydrate(_:)` can genuinely be invoked from two independent call
/// sites for two different ids at once (`ThreadModel.toggleExpanded`'s
/// unstructured `Task` and an `observeThread` re-emit's
/// `loadBodiesForExpandedMessages`, running inside `ThreadModel`'s
/// `observationTask`) — actor isolation is what makes the build-once cache
/// below safe without a separate lock, and makes `LazyHydrator` itself
/// `Sendable` for free, satisfying the closure's own `@Sendable` capture
/// requirement.
private actor LazyHydrator {
    private let database: HudsonDatabase
    private let account: AccountRecord
    private let store: any TokenStore

    /// `nil` until the first `hydrate(_:)` call. Once built, `.some` —
    /// even when the WRAPPED value is itself `nil` (this account has no
    /// stored credentials, matching `SyncBootstrap.makeHydrator`'s own
    /// "no fetch, stays uncached" contract) — so a credential-less account
    /// never repeats the (cheap but pointless) token-store lookup on every
    /// subsequent on-demand fetch for the rest of this `AppModel`'s
    /// lifetime; there's nothing that would make a second attempt succeed
    /// where the first didn't, since `account`/`store` never change here.
    private var body: (@Sendable (String) async -> Bool)??

    init(database: HudsonDatabase, account: AccountRecord, store: any TokenStore) {
        self.database = database
        self.account = account
        self.store = store
    }

    /// Builds `body` on the first call only, then delegates every call
    /// (this one included) to whatever it resolved to. Reentrant-safe: two
    /// overlapping calls for different ids both land on this actor, so the
    /// synchronous build-and-cache (`SyncBootstrap.makeHydrator` does no
    /// awaiting internally) can never interleave with itself — only the
    /// subsequent `await resolved(id)` suspends, by which point `body` is
    /// already settled for good.
    func hydrate(_ id: String) async -> Bool {
        if body == nil {
            body = SyncBootstrap.makeHydrator(database: database, account: account, store: store)
        }
        guard let resolved = body ?? nil else { return false }
        return await resolved(id)
    }
}
