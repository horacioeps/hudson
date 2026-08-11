import Observation

/// One entry in the ⌘K command palette. `id` is stable per distinct
/// command (a fixed string for singletons like `.archive`, or
/// `"switchSplit.<key>"` for a per-split entry) so a palette view's list
/// diffing has something to key on across `filter()` re-runs.
public struct Command: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// Secondary line shown under `title` — currently only used for
    /// Snooze's "Coming soon" placeholder; `nil` for every other command.
    public let subtitle: String?
    /// Keyboard shortcut glyphs to display alongside the row (e.g. `["E"]`
    /// for Archive). Empty when a command has no dedicated shortcut.
    public let keys: [String]
    public let kind: CommandKind
}

/// What a selected command does. `CommandModel` only builds and filters
/// these — it never interprets one. The palette VIEW (a later task) owns a
/// `perform(_ command: Command)` closure that switches on `kind` and calls
/// into `InboxModel`/`ThreadModel`/navigation state; keeping that dispatch
/// out of this file is what makes `CommandModel` testable without a Store
/// or a live view hierarchy.
public enum CommandKind: Sendable, Equatable {
    case archive
    case toggleStar
    case toggleRead
    /// M6 feature — listed in the palette today only as a "Coming soon"
    /// placeholder (see `CommandModel.reload`); carries no behavior yet.
    case snooze
    /// Moves the selected thread to another split. Not yet produced by
    /// `CommandModel.reload` (no per-split "move to" commands exist until
    /// a later task builds them) — the case exists so `Command`'s shape is
    /// already stable for that addition.
    case moveToSplit(String)
    case openSearch
    /// Switches the active split to the one identified by this key
    /// (`SplitTab.key`).
    case switchSplit(String)
}

/// Builds and fuzzy-filters the ⌘K palette's command list. Pure list
/// management only: no Store or network access, and no action dispatch —
/// see `CommandKind`'s doc comment for why dispatch deliberately lives
/// elsewhere.
@MainActor
@Observable
public final class CommandModel {
    /// The palette's search field text. Assigning this does NOT recompute
    /// `results` on its own — call `filter()` afterward (the palette
    /// view's `.onChange` does this). Keeping the two steps separate lets
    /// `filter()` be tested directly, without a live text binding.
    public var query: String = ""

    /// The currently visible command list: every `baseCommands` entry that
    /// matched `query` in the last `filter()` call, best match first.
    public private(set) var results: [Command] = []

    /// The full command list from the last `reload()`, in a fixed base
    /// order. `filter()` re-derives `results` from this every time, so a
    /// `query` edit alone never needs `reload()` to run again.
    private var baseCommands: [Command] = []

    /// Which row in `results` is highlighted for keyboard navigation (Up/
    /// Down move it, Return performs it) — driven by `AppModel`'s global
    /// `KeyboardMonitor`, not view-local state. It has to live here rather
    /// than a view's own `@State`: the monitor is an app-wide `NSEvent`
    /// handler outside any specific view's body, so the only thing it can
    /// drive is model state. Reset to the top row on every `filter()` call
    /// (including the one `reload()` itself makes), so a fresh result set —
    /// a typed character, or opening the palette anew — always starts from
    /// row 0.
    public private(set) var highlightedIndex: Int = 0

    public init() {}

    /// Rebuilds `baseCommands` for the current inbox state, then
    /// re-applies `query` via `filter()`. Call whenever the split list or
    /// the selection changes — typically right before the palette opens.
    ///
    /// Triage commands (archive/star/mark read) only make sense with a
    /// thread selected, so they're included ONLY when `hasSelection` is
    /// true; v1 simply omits them otherwise rather than showing a
    /// disabled row. `openSearch` and one `switchSplit` command per split
    /// tab are always present. `snooze` is always listed too, but as a
    /// "Coming soon" placeholder (M6) so it's discoverable without being
    /// wired to real behavior yet.
    public func reload(splits: [SplitTab], hasSelection: Bool) {
        var commands: [Command] = []

        if hasSelection {
            commands.append(Command(id: "archive", title: "Archive", subtitle: nil, keys: ["E"], kind: .archive))
            commands.append(Command(id: "toggleStar", title: "Star", subtitle: nil, keys: ["S"], kind: .toggleStar))
            commands.append(
                Command(id: "toggleRead", title: "Mark read/unread", subtitle: nil, keys: ["U"], kind: .toggleRead))
        }

        commands.append(Command(id: "openSearch", title: "Search", subtitle: nil, keys: [], kind: .openSearch))
        commands.append(
            Command(id: "snooze", title: "Snooze", subtitle: "Coming soon", keys: [], kind: .snooze))

        for split in splits {
            commands.append(Command(
                id: "switchSplit.\(split.key)",
                title: "Switch to \(split.title)",
                subtitle: nil,
                keys: [],
                kind: .switchSplit(split.key)))
        }

        baseCommands = commands
        filter()
    }

    /// Recomputes `results` from `query` against `baseCommands`, scoring
    /// each command's `title` with `FuzzyMatch`. Commands that don't match
    /// (a `nil` score) are dropped; the rest are sorted best-score-first.
    /// `Array.sorted(by:)` is a stable sort, so commands tied on score keep
    /// their `baseCommands` order — which is exactly why an empty query
    /// (score `0` for everything, per `FuzzyMatch`) reproduces that base
    /// order unchanged.
    public func filter() {
        let scoredCommands = baseCommands.compactMap { command -> (command: Command, score: Int)? in
            guard let score = FuzzyMatch.score(command.title, query: query) else { return nil }
            return (command, score)
        }
        results = scoredCommands.sorted { $0.score > $1.score }.map(\.command)
        highlightedIndex = 0
    }

    // MARK: - Keyboard highlight

    /// `highlightedIndex`, clamped into `results`' actual bounds — guards
    /// the (rare) case `results` shrank out from under a previously-valid
    /// index, e.g. mid-navigation a query change lands with fewer matches.
    public var clampedHighlightedIndex: Int {
        guard !results.isEmpty else { return 0 }
        return min(max(highlightedIndex, 0), results.count - 1)
    }

    /// Moves the highlight by `offset` rows, clamped to `results`' bounds —
    /// `+1`/`-1` for arrow-down/arrow-up. A no-op on an empty result set.
    public func moveHighlight(by offset: Int) {
        guard !results.isEmpty else { return }
        highlightedIndex = min(max(clampedHighlightedIndex + offset, 0), results.count - 1)
    }

    /// The currently-highlighted command, or `nil` when `results` is empty
    /// — what Return should perform.
    public var highlightedCommand: Command? {
        guard results.indices.contains(clampedHighlightedIndex) else { return nil }
        return results[clampedHighlightedIndex]
    }
}
