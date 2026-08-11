import Foundation
import Store

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

    private static let connectAccountBannerText = "Connect an account in Terminal: `hudson auth`"

    /// Opens the store at `databaseURL`, loads the primary account, and
    /// builds every child model. Never touches the Keychain or the network
    /// — the app is read-and-triage until the user explicitly triggers
    /// `syncNow()`.
    public init(databaseURL: URL) async throws {
        let database = try HudsonDatabase.open(at: databaseURL)
        self.database = database
        let account = try await database.primaryAccount()
        self.account = account
        let email = Self.accountEmail(account)
        self.inbox = InboxModel(database: database, account: email)
        self.thread = ThreadModel(database: database, account: email)
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
    /// its first emission to land.
    public init(database: HudsonDatabase, account: AccountRecord?) {
        self.database = database
        self.account = account
        let email = Self.accountEmail(account)
        self.inbox = InboxModel(database: database, account: email)
        self.thread = ThreadModel(database: database, account: email)
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
        return AppModel(database: database, account: account)
    }

    /// No account yet (a fresh install before `hudson auth`) reads back as
    /// an empty account string — every Store read the child models below
    /// make just comes back empty for it, never a crash, so the shell
    /// still renders (empty inbox, empty search) while the user connects
    /// an account in Terminal.
    private static func accountEmail(_ account: AccountRecord?) -> String {
        account?.email ?? ""
    }

    /// Both subscription tasks capture `self` only weakly, so nothing here
    /// keeps `self` alive past this — matches `InboxModel`'s own `isolated
    /// deinit` (SE-0371; `pendingCountTask` is `@MainActor`-isolated
    /// storage, so a plain `nonisolated deinit` can't touch it).
    isolated deinit {
        pendingCountTask?.cancel()
        unreadCountTask?.cancel()
        autoSyncTask?.cancel()
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
            guard let stack = make() else { return }
            while !Task.isCancelled {
                _ = try? await stack.engine.syncOnce()
                _ = try? await stack.flusher.flushOnce()
                await self?.refreshLabels()
                try? await Task.sleep(for: interval)
            }
        }
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
        } catch {
            syncBanner = "Sync failed — check your connection."
        }
    }
}
