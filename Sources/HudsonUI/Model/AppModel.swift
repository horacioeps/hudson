import Foundation
import Store

/// The root of the app's object graph. Owns the open database, the active
/// account, and every child view model (`inbox`/`thread`/`command`/
/// `search`), plus the app-level presentation state (which overlay is
/// showing) and keyboard routing (`apply(_:)`, driven by `KeyboardMonitor`).
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

    /// The sidebar's "LABELS" section — a one-shot read at launch (Store has
    /// no `observeLabels` twin the way inbox rows/split rules do, and this
    /// milestone ships no label-management UI that would need it to be
    /// reactive), refreshed again after `syncNow()` picks up new labels.
    public private(set) var labels: [LabelRecord] = []

    /// Rows currently sitting in `mutation_queue`, waiting to reach Gmail —
    /// backs the sidebar footer's "N pending" / "All synced" text.
    public private(set) var pendingCount: Int = 0
    private var pendingCountTask: Task<Void, Never>?

    /// Whether the ⌘K command palette overlay is showing.
    public var isPaletteVisible = false
    /// Whether the ⌘F/`/` search overlay is showing.
    public var isSearchVisible = false

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
        await inbox.start()
        await refreshLabels()
        subscribeToPendingCount()
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
        let inbox = self.inbox
        Task { await inbox.start() }
        Task { [weak self] in await self?.refreshLabels() }
        subscribeToPendingCount()
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

    private func refreshLabels() async {
        guard let account else { return }
        labels = (try? await database.labels(account: account.email)) ?? []
    }

    // MARK: - Navigation

    /// Selects `threadID` in the inbox list and loads it into the reading
    /// pane. Synchronous (matches `InboxListView`'s `onOpen: (String) ->
    /// Void` and `SearchView`'s `onOpen`) — `thread.open` is async, so it
    /// runs in its own `Task`; `ThreadModel.open` doesn't wait for its
    /// first emission either (see its doc comment), so this doesn't need to.
    public func openThread(_ threadID: String) {
        inbox.selectedThreadID = threadID
        Task { await thread.open(threadID: threadID) }
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
        search.query = ""
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
            search.query = ""
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
        }
    }

    // MARK: - Sync (the ONLY network path in the app — see Privacy #1: user-initiated, never automatic)

    /// TODO(sync-wire): nothing in this milestone's UI calls this yet — the
    /// sidebar's settings gear is still a placeholder (Task 9's doc
    /// comment), and per Privacy #1 sync must stay user-initiated, so it's
    /// deliberately never called automatically (e.g. on launch) either. The
    /// implementation below is real and tested at the "no account/no
    /// credentials" guard (`AppModelTests`); a future task wires an actual
    /// "Sync now" affordance to call it.
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
