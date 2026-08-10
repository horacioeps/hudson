import Foundation

/// Gmail quota-unit costs per API method (spec §4.5, May-2026 pricing).
/// Defined for all of Hudson now; M1 only spends `getProfile`.
public enum GmailQuotaCost {
    public static let getProfile = 1
    public static let historyList = 2
    public static let labelsList = 1
    public static let messagesList = 5
    public static let messagesGet = 20
    public static let messagesSend = 100
    public static let messagesModify = 5
    public static let messagesBatchModify = 50
}

/// Priority lane for a `QuotaBucket` acquirer. `.interactive` is foreground
/// triage — a person waiting on star/read/archive/send — and is admitted
/// against the full per-minute budget, drained ahead of any queued
/// `.background` work. `.background` is everything else (polling, the ~6h
/// backfill, batch modify) and is admitted only up to a reserved-off
/// sub-budget, so it can never saturate the window and make a foreground
/// action queue behind it.
public enum QuotaClass: Sendable {
    case interactive
    case background
}

/// Client-side rolling-minute rate limiter. Google enforces 6,000 quota
/// units/min/user (spec §4.5); we cap ourselves at 5,500 by default so a
/// second device or the Gmail app itself never pushes the account over.
/// `now`/`sleep` are injected so tests run on a virtual clock.
///
/// Two priority lanes share one rolling window (see `QuotaClass`).
/// `interactiveReserve` units/min are held back from `.background`
/// admission so a saturated background lane (the multi-hour backfill) can
/// never starve a foreground triage action. Within a lane, waiters are
/// served strictly FIFO by a single drain task, so a large-cost acquirer
/// (e.g. `messages.send`, cost 100) queued behind sustained small-cost
/// traffic (e.g. `history.list` polling) is never starved by later,
/// cheaper requests that would otherwise fit sooner. Across lanes, every
/// queued `.interactive` waiter is drained before any `.background` waiter
/// is even considered.
///
/// A waiter whose task is cancelled while queued is removed from the queue
/// and resumed with `CancellationError` promptly, instead of sitting until
/// its grant.
public actor QuotaBucket {
    private let unitsPerMinute: Int
    private let interactiveReserve: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Spends inside the current 60s window, oldest first.
    private var spends: [(date: Date, cost: Int)] = []

    /// One queued acquirer. `id` is the sole identity used to find this
    /// entry again — array position shifts as earlier entries are removed,
    /// so lookups are always by id, never by index captured earlier.
    private struct Waiter {
        let id: Int
        let cost: Int
        let quotaClass: QuotaClass
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Queued waiters across both lanes, oldest-arrival first overall.
    /// `drain()` and `cancelWaiter(id:)` are the only two places that ever
    /// touch a `Waiter`'s continuation, and both do it the same way: look
    /// up the entry, remove it from this array, *then* resume — in that
    /// order, with no `await` between the removal and the resume. Because
    /// this actor only ever runs one isolated method body at a time, and
    /// removal happens before resumption, a waiter can be found (and thus
    /// resumed) by at most one of the two: whichever runs first removes it,
    /// and the other's lookup by `id` then simply finds nothing. That's the
    /// entire resume-once discipline — see the doc comments on `drain()`
    /// and `cancelWaiter(id:)`.
    private var waiters: [Waiter] = []
    /// Monotonic counter handing out each waiter's `id`.
    private var nextWaiterID = 0
    /// Whether a drain task is currently running the waiter queue. Only ever
    /// one drain task is active at a time, which is what keeps service order
    /// stable; `acquire` starts one whenever it enqueues into an idle queue.
    private var isDraining = false

    /// Initializes a quota bucket with per-minute unit limit, the
    /// units/min reserved for `.interactive` acquirers, and optional
    /// time/sleep providers.
    public init(
        unitsPerMinute: Int = 5_500,
        interactiveReserve: Int = 1_000,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.unitsPerMinute = unitsPerMinute
        self.interactiveReserve = interactiveReserve
        self.now = now
        self.sleep = sleep
    }

    /// Waits until `cost` units fit in the rolling window, then records
    /// them. Equivalent to `acquire(cost:class:)` with `.background` — the
    /// lane every pre-M3 caller (polling, batch modify) belongs to.
    public func acquire(cost: Int) async throws {
        try await acquire(cost: cost, class: .background)
    }

    /// Waits until `cost` units fit in the rolling window for `quotaClass`,
    /// then records them. Service order is strict FIFO within a lane, and
    /// every queued `.interactive` waiter is served before any
    /// `.background` waiter: a request only takes the fast (no-wait) path
    /// when the whole waiter queue — both lanes — is empty, so it can never
    /// cut ahead of an already-queued acquirer even if it would otherwise
    /// fit immediately.
    ///
    /// If the calling task is cancelled while this call is queued, the
    /// waiter is removed and this throws `CancellationError` promptly
    /// instead of sitting until it would otherwise be granted.
    public func acquire(cost: Int, class quotaClass: QuotaClass) async throws {
        let ceiling = admissionCeiling(for: quotaClass)
        guard cost <= ceiling else {
            throw GmailError.invalidRequest(
                status: 0,
                message: "Quota cost \(cost) exceeds the \(quotaClass) budget of \(ceiling) "
                    + "units/min.")
        }
        // The drain task does not inherit a waiter's cancellation (it's
        // detached from any one waiter's task — see `drain()`), so a caller
        // that enters `acquire` already cancelled would otherwise sit in
        // the queue until its grant instead of failing promptly. This
        // catches that case; `withTaskCancellationHandler` below handles
        // cancellation that arrives *after* the waiter is queued.
        try Task.checkCancellation()
        pruneExpiredSpends()
        if waiters.isEmpty && fits(cost: cost, class: quotaClass) {
            spends.append((now(), cost))
            return
        }

        let id = nextWaiterID
        nextWaiterID += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Runs synchronously, still on this actor's executor, so
                // this is the true, race-free registration point — no
                // suspension happens between the append below and the
                // `isDraining` check, so a waiter can never be enqueued
                // into a window where `drain()` has already seen the queue
                // empty and is about to (or just did) flip `isDraining`
                // false without observing this entry.
                waiters.append(
                    Waiter(id: id, cost: cost, quotaClass: quotaClass, continuation: continuation))
                if !isDraining {
                    isDraining = true
                    Task { await self.drain() }
                }
            }
        } onCancel: {
            // Hops onto the actor to remove this specific waiter (by id)
            // and resume it. Runs concurrently with whatever the actor is
            // doing; `cancelWaiter(id:)` is written to be safe no matter
            // when it actually gets scheduled relative to `drain()` — see
            // its doc comment.
            Task { await self.cancelWaiter(id: id) }
        }
    }

    /// Removes a still-queued waiter (by id) and resumes it with
    /// `CancellationError`. If `drain()` already granted (and removed)
    /// this waiter by the time this runs — the cancellation arrived just
    /// after the grant — `firstIndex(where:)` finds nothing and this is a
    /// no-op: the continuation was already resumed by `drain()`, and this
    /// method only ever resumes a continuation it itself just removed.
    /// Symmetrically, once this method removes a waiter, `drain()` can no
    /// longer find it either. Both consult the same `waiters` array, both
    /// run as isolated methods on this actor's serial executor (so they
    /// can never overlap), and both remove an entry from `waiters` in the
    /// same synchronous step — with no `await` in between — that resumes
    /// its continuation. So exactly one of the two ever resumes a given
    /// waiter's continuation, however the two happen to be scheduled.
    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Serves waiters in priority order: all `.interactive` waiters (FIFO)
    /// before any `.background` waiter, so a saturated background lane can
    /// never make foreground triage wait behind it. Sleeps until the head
    /// of whichever lane is up next fits, grants it (removing it from
    /// `waiters` and resuming its continuation in one synchronous step —
    /// see `cancelWaiter(id:)`'s doc comment for why that makes resume-once
    /// hold), and moves on. Only ever one drain task (`isDraining`), so
    /// service order is stable.
    private func drain() async {
        while let index = nextServable() {
            pruneExpiredSpends()
            let waiter = waiters[index]
            if fits(cost: waiter.cost, class: waiter.quotaClass) {
                waiters.remove(at: index)
                spends.append((now(), waiter.cost))
                waiter.continuation.resume()
                continue
            }
            let oldest = spends[0].date  // non-empty: head doesn't fit, so something is spent
            let wait = max(60 - now().timeIntervalSince(oldest), 0.05)
            do { try await sleep(wait) } catch {
                // Unreachable with the production `sleep` (plain
                // `Task.sleep`, and this task — `drain()` — is never itself
                // cancelled: it's detached from any waiter's task, so a
                // caller cancelling its own `acquire` call does not cancel
                // `drain`). Only reachable in tests that inject a throwing
                // `sleep`. Kept as a fail-safe: fail every queued waiter,
                // in both lanes, rather than hang.
                while !waiters.isEmpty {
                    waiters.removeFirst().continuation.resume(throwing: error)
                }
            }
        }
        isDraining = false
    }

    /// Index (into `waiters`) of the waiter `drain()` should attempt next:
    /// the earliest-arrived `.interactive` waiter if one is queued,
    /// otherwise the earliest-arrived `.background` waiter. `nil` only
    /// when both lanes are empty. This is what makes "all interactive
    /// before any background" hold even while the interactive head doesn't
    /// yet fit: `drain()` keeps sleeping and re-checking that same
    /// interactive waiter rather than falling through to background.
    private func nextServable() -> Int? {
        if let interactiveIndex = waiters.firstIndex(where: { $0.quotaClass == .interactive }) {
            return interactiveIndex
        }
        return waiters.indices.first
    }

    /// The most units `quotaClass` may have spent in the current window,
    /// including a new acquisition. `.interactive` may use the full
    /// per-minute budget; `.background` is capped below it by
    /// `interactiveReserve`, so that headroom stays free for interactive
    /// traffic that arrives after `.background` is already queued.
    private func admissionCeiling(for quotaClass: QuotaClass) -> Int {
        switch quotaClass {
        case .interactive: return unitsPerMinute
        case .background: return max(unitsPerMinute - interactiveReserve, 0)
        }
    }

    private func fits(cost: Int, class quotaClass: QuotaClass) -> Bool {
        spentInWindow() + cost <= admissionCeiling(for: quotaClass)
    }

    private func spentInWindow() -> Int { spends.reduce(0) { $0 + $1.cost } }

    private func pruneExpiredSpends() {
        let cutoff = now().addingTimeInterval(-60)
        spends.removeAll { $0.date <= cutoff }
    }
}
