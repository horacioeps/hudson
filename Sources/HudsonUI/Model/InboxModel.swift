import Foundation
import Store

/// One tab in the inbox's split-view header — see `InboxModel.buildTabs`
/// for how the set (and each tab's `count`) is derived. `Identifiable` via
/// `key` so a later view's `ForEach` doesn't need a separate id.
public struct SplitTab: Identifiable, Sendable, Equatable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let count: Int
}

/// The inbox list's view model: owns the observed rows for the active
/// split, the split-tab strip, j/k keyboard selection, and optimistic
/// triage. `@MainActor` because SwiftUI reads `rows`/`tabs`/
/// `selectedThreadID` on the main thread, and every Store call here is
/// async — nothing on this class blocks a cooperative-pool thread.
@MainActor
@Observable
public final class InboxModel {
    public let database: HudsonDatabase
    public let account: String

    public private(set) var rows: [ThreadRow] = []
    /// Always has a leading `primary` entry, even before `start()` has run
    /// or on a freshly-created (unseeded) account — matches what
    /// `buildTabs` returns for an empty rule set and an empty inbox.
    public private(set) var tabs: [SplitTab] = [InboxModel.primaryTab(count: 0)]
    public var selectedThreadID: String?

    /// `nil` shows the whole inbox; a split key restricts `rows` to that
    /// one split. Setting a NEW value re-subscribes `rows`' observation —
    /// see `didSet`. The tab strip itself is unaffected (it always spans
    /// every split, not just the active one), so `tabsTask` isn't touched
    /// here.
    public var activeSplit: String? {
        didSet {
            guard oldValue != activeSplit else { return }
            subscribeToRows()
        }
    }

    /// Which sidebar folder the list is showing. `.inbox` is the split-view
    /// (with the tab strip); `.label` is a flat "threads carrying this label"
    /// list (Starred / Sent / a user label / Snoozed). Switching re-subscribes
    /// `rows` to the matching observation and clears the selection.
    public enum Mailbox: Equatable, Sendable {
        case inbox
        case label(id: String, title: String)
    }
    public var mailbox: Mailbox = .inbox {
        didSet {
            guard oldValue != mailbox else { return }
            selectedThreadID = nil
            subscribeToRows()
        }
    }

    /// The header title for the current folder ("Inbox" or the label's name).
    public var folderTitle: String {
        switch mailbox {
        case .inbox: return "Inbox"
        case .label(_, let title): return title
        }
    }

    /// The split-tab strip belongs to the inbox only — a flat label folder
    /// shows a plain title instead.
    public var showsSplitTabs: Bool {
        if case .inbox = mailbox { return true }
        return false
    }

    /// The subscription driving `rows`, (re)started by `start()` and by
    /// `activeSplit`'s `didSet`. Stored so a stale subscription can be
    /// cancelled before the next one starts — otherwise two overlapping
    /// `for try await` loops could race to write `rows` out of order.
    private var rowsTask: Task<Void, Never>?
    /// The subscription driving `tabs` from the account's split rules.
    /// Independent of `rowsTask`/`activeSplit` — the tab strip needs the
    /// full rule set regardless of which single split is active.
    private var tabsTask: Task<Void, Never>?
    /// The latest emission from `observeSplitRules`, cached so a `rows`
    /// re-emit (the common case — every triage action re-emits
    /// `observeInboxThreads`) can recompute `tabs`' counts without waiting
    /// for the much rarer rules stream to also re-emit.
    private var latestSplitRules: [SplitRule] = []

    /// Bounds every inbox read here — generous enough for a single-pane
    /// list, small enough to keep `ValueObservation`'s whole-query re-run
    /// (Task 3's documented tradeoff: it re-runs the full SELECT, up to
    /// `limit` rows, on every relevant write) cheap.
    private static let rowLimit = 200

    public init(database: HudsonDatabase, account: String) {
        self.database = database
        self.account = account
    }

    /// Both subscription tasks capture `self` only weakly (see
    /// `subscribeToRows`/`subscribeToTabs`), so nothing here keeps `self`
    /// alive — this just stops two loops that would otherwise keep polling
    /// GRDB's change notifications for no reason once nobody holds the
    /// model anymore. `isolated` (SE-0371) because `rowsTask`/`tabsTask`
    /// are `@MainActor`-isolated storage — a plain `nonisolated deinit`
    /// can't touch them without an unsafe escape hatch.
    isolated deinit {
        rowsTask?.cancel()
        tabsTask?.cancel()
    }

    /// Begins observing the inbox for `activeSplit` and the account's split
    /// rules. Safe to call more than once (e.g. a view re-appearing) — each
    /// call cancels whatever was running first. Returns immediately once
    /// both loops are launched; it does not wait for their first emission
    /// (a caller that needs the first `rows`/`tabs` to have landed awaits
    /// that separately, e.g. in a test).
    public func start() async {
        subscribeToRows()
        subscribeToTabs()
    }

    // MARK: - Subscriptions

    private func subscribeToRows() {
        rowsTask?.cancel()
        let split = activeSplit
        let mailbox = self.mailbox
        let database = self.database
        let account = self.account
        rowsTask = Task { [weak self] in
            do {
                switch mailbox {
                case .inbox:
                    // The inbox: split-filtered, and it maintains the tab-count
                    // strip. With no active split, `newRows` already IS every
                    // inbox thread, so reuse it (triage re-emits this loop
                    // constantly — avoiding the redundant fetch matters).
                    for try await newRows in database.observeInboxThreads(
                        account: account, split: split, limit: Self.rowLimit
                    ) {
                        guard let self, !Task.isCancelled else { return }
                        self.rows = newRows
                        await self.refreshTabCounts(usingFullInboxRows: split == nil ? newRows : nil)
                    }
                case .label(let id, _):
                    // A flat label folder (Sent/Starred/…): no splits, no tab
                    // strip, so nothing to recompute — just the rows.
                    for try await newRows in database.observeThreadsWithLabel(
                        account: account, labelID: id, limit: Self.rowLimit
                    ) {
                        guard let self, !Task.isCancelled else { return }
                        self.rows = newRows
                    }
                }
            } catch {
                // The observation only throws on a genuine Store/SQLite failure
                // (never "no rows") — nothing to recover into here.
            }
        }
    }

    private func subscribeToTabs() {
        tabsTask?.cancel()
        let database = self.database
        let account = self.account
        tabsTask = Task { [weak self] in
            do {
                for try await rules in database.observeSplitRules(account: account) {
                    guard let self, !Task.isCancelled else { return }
                    self.latestSplitRules = rules
                    // Always a fresh full-inbox fetch here (never reused
                    // from `rows`): this loop fires independently of
                    // `activeSplit`/`rowsTask`, so `rows` may not hold the
                    // whole inbox — and rule edits are rare, so the extra
                    // query costs nothing in practice.
                    await self.refreshTabCounts(usingFullInboxRows: nil)
                }
            } catch {
                // See `subscribeToRows`'s doc comment — same rationale.
            }
        }
    }

    /// Recomputes `tabs` from `latestSplitRules` plus every inbox thread.
    /// `usingFullInboxRows`, when given, is exactly that "every inbox
    /// thread" list, sparing a redundant `split: nil` fetch when the
    /// caller already has it in hand (see `subscribeToRows`).
    private func refreshTabCounts(usingFullInboxRows: [ThreadRow]?) async {
        let fullInboxRows: [ThreadRow]
        if let usingFullInboxRows {
            fullInboxRows = usingFullInboxRows
        } else if let fetched = try? await database.inboxThreads(
            account: account, split: nil, limit: Self.rowLimit
        ) {
            fullInboxRows = fetched
        } else {
            return  // a transient read failure here just skips this refresh; the next emit retries
        }
        tabs = Self.buildTabs(rules: latestSplitRules, rows: fullInboxRows)
    }

    // MARK: - Tab derivation (static, pure — easy to test in isolation)

    /// Builds the tab strip: a leading `primary` tab (always present, even
    /// at count 0), then every OTHER split — first the account's configured
    /// rules (in `ordinal` order, so a freshly-added rule shows up at count
    /// 0 before any mail has matched it yet), then whatever additional
    /// split keys are actually present among `rows` but aren't covered by
    /// any rule (Gmail's own `CATEGORY_*` fallbacks — see
    /// `SplitInbox.computeSplit`). Each tab's `count` is how many of `rows`
    /// currently carry that `splitKey`.
    static func buildTabs(rules: [SplitRule], rows: [ThreadRow]) -> [SplitTab] {
        var countsBySplitKey: [String: Int] = [:]
        for row in rows {
            countsBySplitKey[row.splitKey, default: 0] += 1
        }

        var orderedKeys: [String] = []
        var seenKeys: Set<String> = ["primary"]  // handled separately below, so never duplicated here
        for rule in rules.sorted(by: { $0.ordinal < $1.ordinal }) {
            if seenKeys.insert(rule.splitName).inserted {
                orderedKeys.append(rule.splitName)
            }
        }
        for row in rows {
            if seenKeys.insert(row.splitKey).inserted {
                orderedKeys.append(row.splitKey)
            }
        }

        var tabs = [primaryTab(count: countsBySplitKey["primary", default: 0])]
        tabs.append(contentsOf: orderedKeys.map { key in
            SplitTab(key: key, title: titleCased(key), count: countsBySplitKey[key, default: 0])
        })
        return tabs
    }

    private static func primaryTab(count: Int) -> SplitTab {
        SplitTab(key: "primary", title: "Primary", count: count)
    }

    /// `"important"` -> `"Important"`, `"updates"` -> `"Updates"`. Every
    /// split key in practice is a single lowercase word — a rule's
    /// `splitName` or one of `SplitInbox`'s fixed category names — so
    /// capitalizing the first character is sufficient; this is not a
    /// general title-casing algorithm.
    private static func titleCased(_ key: String) -> String {
        guard let first = key.first else { return key }
        return first.uppercased() + key.dropFirst()
    }

    // MARK: - j/k selection

    /// The full row for `selectedThreadID`, or `nil` once that thread has
    /// dropped out of `rows` — e.g. right after an archive, before
    /// `selectedThreadID` itself has been reassigned. Triage actions below
    /// no-op rather than crash when this is `nil`.
    private var selectedRow: ThreadRow? {
        guard let selectedThreadID else { return nil }
        return rows.first { $0.threadID == selectedThreadID }
    }

    /// Moves `selectedThreadID` to the row after the current selection,
    /// clamping at the last row; selects the first row if nothing is
    /// selected yet (or the prior selection has scrolled out of `rows`).
    /// Mirrors Superhuman/Gmail's `j` navigation — a later task's key-event
    /// handler maps `j` to this.
    public func selectNext() {
        move(by: 1)
    }

    /// Same as `selectNext`, one row back — `k`. Clamps at the first row.
    public func selectPrevious() {
        move(by: -1)
    }

    private func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        // Named distinctly from the `selectedThreadID` property (rather
        // than shadowing it via `guard let selectedThreadID`) so the
        // assignments below unambiguously write the property, not a local
        // binding that would otherwise stay in scope for the rest of this
        // function.
        guard let currentSelection = selectedThreadID,
            let currentIndex = rows.firstIndex(where: { $0.threadID == currentSelection })
        else {
            selectedThreadID = rows.first?.threadID
            return
        }
        let clampedIndex = min(max(currentIndex + offset, 0), rows.count - 1)
        selectedThreadID = rows[clampedIndex].threadID
    }

    // MARK: - Optimistic triage

    /// Archives the selected thread — Gmail's own "leave the inbox"
    /// semantics, applied thread-wide (`Triage.archiveThread`), not just to
    /// the newest message: `thread_rollup.in_inbox` is an OR across every
    /// message in the thread, so archiving only `lastMessageID` would
    /// silently no-op whenever an older message still carries `INBOX` (the
    /// common shape for any real multi-message conversation). We never
    /// remove the row from `rows` ourselves: `enqueueMutation` recomputes
    /// `thread_rollup` in the same transaction, and `rowsTask`'s
    /// observation re-emits without this thread moments later — see
    /// `Triage`'s doc comment.
    public func archiveSelected() async throws {
        guard let selectedRow else { return }
        try await Triage.archiveThread(threadID: selectedRow.threadID, account: account, database: database)
    }

    /// Stars the selected thread's newest message, or unstars it if
    /// already starred. `ThreadRow` carries no `starred` flag (only
    /// `unread`/`inInbox`), so the current state is read fresh from the
    /// message's effective labels via `message(id:account:)` — the same
    /// overlay-aware label read the thread view (a later task) uses.
    public func toggleStarSelected() async throws {
        guard let selectedRow else { return }
        let messageID = selectedRow.lastMessageID
        let isStarred = try await database.message(id: messageID, account: account)?
            .row.labelIDs.contains("STARRED") ?? false
        if isStarred {
            try await Triage.unstar(messageID: messageID, account: account, database: database)
        } else {
            try await Triage.star(messageID: messageID, account: account, database: database)
        }
    }

    /// Marks the selected thread read (thread-wide, `Triage.markReadThread`
    /// — `thread_rollup.unread` is likewise an OR across every message, so
    /// clearing `UNREAD` on only `lastMessageID` would no-op whenever an
    /// older message is still unread), or marks just the newest message
    /// unread if the thread is currently read. Marking unread IS a
    /// single-message action in Gmail itself (there's no "mark whole
    /// thread unread" affordance to mirror), so that direction stays
    /// scoped to `lastMessageID`. `ThreadRow.unread` is already the
    /// thread's effective state (overlay-composed by `thread_rollup`), so —
    /// unlike star — no extra read is needed to pick the direction.
    public func toggleReadSelected() async throws {
        guard let selectedRow else { return }
        if selectedRow.unread {
            try await Triage.markReadThread(threadID: selectedRow.threadID, account: account, database: database)
        } else {
            try await Triage.markUnread(
                messageID: selectedRow.lastMessageID, account: account, database: database)
        }
    }
}
