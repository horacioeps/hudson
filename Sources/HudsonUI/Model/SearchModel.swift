import Foundation
import Observation
import Store

/// The search field's view model: turns each keystroke (and every scope
/// change) into a debounced, cancellable call to `searchMessages`.
/// `@MainActor` for the same reason as `InboxModel`/`ThreadModel` — SwiftUI
/// reads `hits`/`isSearching` on the main thread, and the search itself is
/// async, so nothing here blocks a cooperative-pool thread.
///
/// **Debounce via cancellable sleep:** rather than a timer, `queryChanged()`
/// launches a `Task` that first `sleep`s for `debounce`, then runs the
/// search. Each call cancels the PREVIOUS task before starting a new one
/// (see `searchTask`), so a keystroke that arrives before the sleep elapses
/// throws that in-flight task away before it ever touches the database —
/// only a query the user pauses on for a full `debounce` interval actually
/// searches.
///
/// **Only-final-query-wins:** cancel-before-restart alone isn't quite
/// enough — a task already past its sleep, mid-`await` on the database read,
/// could still land after being superseded. Every state write after an
/// `await` is therefore guarded by `Task.isCancelled` (or a caught
/// `CancellationError`), so a stale search can never clobber `hits` with
/// results for a query that's no longer current.
///
/// **Floor short-circuit:** below the 2-char floor `searchMessages` already
/// enforces internally, `queryChanged()` clears `hits` and returns without
/// even creating a task — there's no reason to debounce, let alone query,
/// a search that's guaranteed to come back empty.
@MainActor
@Observable
public final class SearchModel {
    public let database: HudsonDatabase
    public let account: String

    /// The search field's live text. Setting this alone does NOT trigger a
    /// search — call `queryChanged()` afterward (a view's `.onChange` does
    /// this), matching `CommandModel.query`'s split between text and
    /// action.
    public var query: String = ""

    /// Which mailbox subset results are drawn from. Defaults to `.all`;
    /// changing this should be followed by `queryChanged()` too (a scope
    /// toggle re-searches the current `query` under the new scope).
    public var scope: SearchScope = .all

    public private(set) var hits: [SearchHit] = []

    /// True from the moment a search is scheduled (immediately after the
    /// floor check passes) until its results land — spans the debounce
    /// sleep AND the database read, so a view can show a spinner for the
    /// whole "waiting on this query" window, not just the network/DB part.
    public private(set) var isSearching: Bool = false

    /// How long `queryChanged()` waits, uncancelled, before actually
    /// querying the database. Injectable so tests can shrink it to a few
    /// milliseconds and stay fast; defaults to a value short enough to feel
    /// instant while still absorbing a fast typist's keystrokes.
    private let debounce: Duration

    /// The task backing the most recent `queryChanged()` call — sleeping
    /// for `debounce`, then searching. Stored so the NEXT `queryChanged()`
    /// can cancel it before starting its own, which is what makes the
    /// debounce and the only-final-wins guarantee work.
    private var searchTask: Task<Void, Never>?

    /// Generous enough for a search results list, small enough to keep a
    /// single query cheap — matches the bound `InboxModel.rowLimit` uses
    /// for its own list reads.
    private static let resultLimit = 100

    public init(database: HudsonDatabase, account: String, debounce: Duration = .milliseconds(150)) {
        self.database = database
        self.account = account
        self.debounce = debounce
    }

    /// `isolated` (SE-0371) because `searchTask` is `@MainActor`-isolated
    /// storage — a plain `nonisolated deinit` can't touch it without an
    /// unsafe escape hatch. Only cancels the in-flight task; nothing else
    /// keeps `self` alive past this since the task captures it weakly (see
    /// `queryChanged`).
    isolated deinit {
        searchTask?.cancel()
    }

    /// Call on every keystroke and on every `scope` change. See the type's
    /// doc comment for the debounce/cancellation/floor rationale.
    public func queryChanged() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            // Below the floor `searchMessages` enforces anyway — clear
            // immediately and skip scheduling a task entirely, so a user
            // who backspaces down to 1 character never even starts a
            // debounce that would just come back empty.
            hits = []
            isSearching = false
            return
        }

        isSearching = true
        let database = self.database
        let account = self.account
        let scope = self.scope
        let debounce = self.debounce
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return  // cancelled during the debounce — a newer keystroke won the race
            }
            guard !Task.isCancelled else { return }

            let results: [SearchHit]
            do {
                results = try await database.searchMessages(
                    account: account, query: trimmed, limit: Self.resultLimit, scope: scope)
            } catch is CancellationError {
                return  // a newer keystroke won the race — that task owns `isSearching` now
            } catch {
                // A genuine Store/SQLite failure (disk full, corruption, …). There is no
                // error surface in the UI yet (matching InboxModel's deferred error-UI stance),
                // but we MUST clear the spinner: this is the last, non-superseded search, so if
                // nothing flips `isSearching` back it stays stuck true forever. Guarded so a
                // simultaneously-cancelled task defers to whichever newer task is now running.
                guard !Task.isCancelled, let self else { return }
                self.isSearching = false
                return
            }

            guard !Task.isCancelled, let self else { return }
            self.hits = results
            self.isSearching = false
        }
    }
}
