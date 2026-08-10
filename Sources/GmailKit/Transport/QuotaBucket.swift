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
}

/// Client-side rolling-minute rate limiter. Google enforces 6,000 quota
/// units/min/user (spec §4.5); we cap ourselves at 5,500 by default so a
/// second device or the Gmail app itself never pushes the account over.
/// `now`/`sleep` are injected so tests run on a virtual clock.
///
/// Waiters are served strictly FIFO by a single drain task, so a large-cost
/// acquirer (e.g. `messages.send`, cost 100) queued behind sustained
/// small-cost traffic (e.g. `history.list` polling) is never starved by
/// later, cheaper requests that would otherwise fit sooner.
public actor QuotaBucket {
    private let unitsPerMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Spends inside the current 60s window, oldest first.
    private var spends: [(date: Date, cost: Int)] = []
    /// FIFO queue: heads are served strictly before later arrivals, even when
    /// a later, cheaper request would fit sooner (prevents starvation of
    /// large-cost calls like messages.send behind polling traffic).
    private var waiters: [(cost: Int, continuation: CheckedContinuation<Void, Error>)] = []
    /// Whether a drain task is currently running the waiter queue. Only ever
    /// one drain task is active at a time, which is what keeps service order
    /// stable; `acquire` starts one whenever it enqueues into an idle queue.
    private var isDraining = false

    /// Initializes a quota bucket with per-minute unit limit and optional time/sleep providers.
    public init(
        unitsPerMinute: Int = 5_500,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.unitsPerMinute = unitsPerMinute
        self.now = now
        self.sleep = sleep
    }

    /// Waits until `cost` units fit in the rolling window, then records them.
    /// Service order is strict FIFO: a request only takes the fast (no-wait)
    /// path when the waiter queue is empty, so it can never cut ahead of an
    /// already-queued acquirer even if it would otherwise fit immediately.
    public func acquire(cost: Int) async throws {
        guard cost <= unitsPerMinute else {
            throw GmailError.invalidRequest(
                status: 0,
                message: "Quota cost \(cost) exceeds the per-minute budget of \(unitsPerMinute).")
        }
        // The drain task does not inherit a waiter's cancellation (that's a
        // deferred redesign — see the catch below), so a caller that enters
        // `acquire` already cancelled would otherwise sit in the queue until
        // its grant instead of failing promptly. This catches that case;
        // it does not help a caller cancelled *after* it starts waiting.
        try Task.checkCancellation()
        pruneExpiredSpends()
        if waiters.isEmpty && spentInWindow() + cost <= unitsPerMinute {
            spends.append((now(), cost))
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((cost, continuation))
            // `isDraining` is only ever flipped on this actor's serial
            // executor, and this whole closure runs synchronously within
            // that continuation body — no suspension happens between the
            // append above and this check — so a waiter can never be
            // enqueued into a window where drain() has already seen the
            // queue empty and is about to (or just did) flip `isDraining`
            // false without observing this entry.
            if !isDraining {
                isDraining = true
                Task { await self.drain() }
            }
        }
    }

    /// Serves waiters in order; sleeps until the head's cost fits, grants it,
    /// moves on. Only ever one drain task (isDraining), so order is stable.
    private func drain() async {
        while let head = waiters.first {
            pruneExpiredSpends()
            if spentInWindow() + head.cost <= unitsPerMinute {
                spends.append((now(), head.cost))
                waiters.removeFirst().continuation.resume()
                continue
            }
            let oldest = spends[0].date  // non-empty: head doesn't fit, so something is spent
            let wait = max(60 - now().timeIntervalSince(oldest), 0.05)
            do { try await sleep(wait) } catch {
                // Unreachable with the production `sleep` (plain `Task.sleep`,
                // and this task — `drain()` — is never itself cancelled: it's
                // detached from any waiter's task, so a caller cancelling its
                // own `acquire` call does not cancel `drain`). Only reachable
                // in tests that inject a throwing `sleep`. Kept as a
                // fail-safe: fail every queued waiter rather than hang.
                while let waiter = waiters.first {
                    waiters.removeFirst()
                    waiter.continuation.resume(throwing: error)
                }
            }
        }
        isDraining = false
    }

    private func spentInWindow() -> Int { spends.reduce(0) { $0 + $1.cost } }

    private func pruneExpiredSpends() {
        let cutoff = now().addingTimeInterval(-60)
        spends.removeAll { $0.date <= cutoff }
    }
}
