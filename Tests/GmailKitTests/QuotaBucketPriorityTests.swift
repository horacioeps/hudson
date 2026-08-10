import Foundation
import Testing
@testable import GmailKit

// Reuse VirtualClock / LockedOrder patterns from the existing QuotaBucket tests.

/// Drives QuotaBucket with a manual clock: `sleep` advances virtual time
/// instead of really sleeping, so tests are instant and deterministic.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 0)
    private(set) var totalSlept: TimeInterval = 0

    var now: Date { lock.withLock { time } }
    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            time += seconds
            totalSlept += seconds
        }
    }
}

/// Thread-safe ordered event log for the priority-order test.
private final class LockedOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
    var values: [String] { lock.withLock { events } }
}

/// A fires-once/awaits-once gate. Confirms a waiter has genuinely reached
/// its wait point instead of guessing a fixed real-time delay. Mirrors
/// `OneShotSignal` in QuotaBucketTests.swift (private to that file, so
/// redefined here).
private actor OneShotSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@Test func interactiveIsServedAheadOfQueuedBackground() async throws {
    let clock = VirtualClock()
    // Deviates from the brief's literal costs (80 priming / 30 bg / 15 fg)
    // and its fixed `Task.sleep(for: .milliseconds(50))` synchronization,
    // for two independent reasons found by running the brief's literal
    // version repeatedly (per the flake-check instructions):
    //
    // 1. Impossible priming call: with interactiveReserve 40, background's
    //    own admission ceiling is unitsPerMinute - interactiveReserve = 60.
    //    A background-classed priming acquire of cost 80 could never be
    //    admitted at all — it exceeds even an *empty* window's background
    //    ceiling, so it would sit queued forever (and `drain()` would
    //    index into an empty `spends` array on its very first fit-check,
    //    since nothing has ever been granted to compute a rollover wait
    //    from). Priming with 55 (fits: 0+55<=60) reaches the same
    //    qualitative scenario without that impossibility.
    // 2. A fixed real-time delay to "assume bg has enqueued by now" races
    //    the child task's own scheduling — the same class of flakiness
    //    already documented on `acquirersAreServedStrictlyInArrivalOrder`
    //    in QuotaBucketTests.swift. Fixed the same way: a deterministic
    //    signal fired from inside the injected `sleep`, confirming `bg`
    //    has genuinely enqueued and `drain()` is genuinely waiting on the
    //    window, instead of guessing.
    //
    // A third, subtler issue (also from that same historical fix) applies
    // here too: with `bg` costing 30, once the window rolls and `fg`
    // (spent 0+15) is granted, `bg` (15+30=45<=60) would *also* fit and
    // get granted in the very same synchronous drain() burst — so which
    // of the two resumed tasks actually runs its post-resume
    // `order.append` first becomes an unresolvable race, exactly as
    // documented there. Costing `bg` at 50 instead avoids that: after
    // `fg` is granted (spent becomes 15), 15+50=65 still exceeds the
    // background ceiling (60), so `bg` needs a *second*, separately-real-
    // delayed drain cycle — giving `fg`'s post-resume code a genuine
    // ~200ms real head start before `bg` is even reconsidered.
    let bgIsWaiting = OneShotSignal()
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 40,
                             now: { clock.now }, sleep: { seconds in
        await bgIsWaiting.fire()
        try? await Task.sleep(for: .milliseconds(200))
        clock.sleep(seconds)
    })
    try await bucket.acquire(cost: 55, class: .background)  // window at 55/100; background ceiling is 60
    let order = LockedOrder()
    async let bg: Void = { try await bucket.acquire(cost: 50, class: .background); order.append("bg") }()
    await bgIsWaiting.wait()  // deterministic: bg has enqueued and drain is genuinely waiting on the window
    async let fg: Void = { try await bucket.acquire(cost: 15, class: .interactive); order.append("fg") }()
    _ = try await (bg, fg)
    // Interactive fits within the full window once the priming spend ages
    // out (0+15<=100); background does not fit within its reserved-down
    // ceiling even after that (15+50=65>60) and needs a further window
    // roll — so fg is admitted first even though bg queued first.
    #expect(order.values.first == "fg")
}

@Test func cancelledWaiterThrowsPromptly() async throws {
    let clock = VirtualClock()
    // Deviates from the brief in two ways, both needed to avoid a flaky/
    // impossible test rather than exercising the intended behavior:
    //
    // 1. `interactiveReserve: 0` (explicit, not the 1,000 default) — same
    //    reason as QuotaBucketTests.swift's legacy tests: the default is
    //    sized for the production unitsPerMinute (5,500), and left at that
    //    default against this test's 100-unit window it makes the
    //    background ceiling 0, so even the priming `acquire(cost: 100,
    //    class: .background)` below would be rejected outright instead of
    //    succeeding.
    // 2. The injected `sleep` fires a deterministic "waiter is genuinely
    //    queued" signal and then adds a real 200ms delay before resolving
    //    virtually, replacing the brief's fixed real
    //    `Task.sleep(for: .milliseconds(50))` before calling `task.cancel()`.
    //    With a purely-synchronous virtual-clock `sleep`, `drain()` never
    //    actually suspends in real time — it resolves the queued waiter's
    //    wait near-instantly on the actor, likely *before* a fixed real
    //    50ms elapses, so `task.cancel()` would race an already-completed
    //    acquire instead of a genuinely still-queued one (the same class
    //    of race documented on `acquirersAreServedStrictlyInArrivalOrder`
    //    in QuotaBucketTests.swift, fixed there the same way: a real delay
    //    inside `sleep` gives the intended ordering a comfortable window).
    let waiterIsQueued = OneShotSignal()
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 0,
                             now: { clock.now }, sleep: { seconds in
        await waiterIsQueued.fire()
        try? await Task.sleep(for: .milliseconds(200))
        clock.sleep(seconds)
    })
    try await bucket.acquire(cost: 100, class: .background)  // saturate
    let task = Task { try await bucket.acquire(cost: 50, class: .background) }
    await waiterIsQueued.wait()  // deterministic: the waiter has genuinely enqueued and drain is waiting
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func existingAcquireDefaultsToBackground() async throws {
    // Deviates from the brief's literal `QuotaBucket(unitsPerMinute: 100)`:
    // that pairs a 100-unit window with the default 1,000-unit
    // interactiveReserve, making the background ceiling 0 and rejecting
    // even this 10-unit acquire outright. Using the full production
    // defaults (unitsPerMinute: 5,500, interactiveReserve: 1,000 — a
    // background ceiling of 4,500) is a more faithful test of "the M2
    // default signature still compiles and behaves as background" than
    // introducing an incompatible override would have been.
    let bucket = QuotaBucket()
    try await bucket.acquire(cost: 10)  // M2 signature still compiles, behaves as background
}
