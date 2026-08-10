import Foundation
import Testing
@testable import GmailKit

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

@Test func underCapacityNeverSleeps() async throws {
    let clock = VirtualClock()
    // `interactiveReserve: 0` — these legacy (pre-M3) tests predate the
    // priority-lane concept and exercise plain `acquire(cost:)`
    // (`.background`), so they need the full `unitsPerMinute` usable by
    // that lane, same as before M3. The default `interactiveReserve`
    // (1,000) is sized for the production default `unitsPerMinute`
    // (5,500); left at that default here it would swallow this whole
    // 100-unit test window and make every `.background` acquire
    // unadmittable.
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 0,
                              now: { clock.now }, sleep: { clock.sleep($0) })
    for _ in 0..<5 { try await bucket.acquire(cost: 20) }  // exactly 100 units
    #expect(clock.totalSlept == 0)
}

@Test func overCapacityWaitsForWindowToRoll() async throws {
    let clock = VirtualClock()
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 0,  // see underCapacityNeverSleeps
                              now: { clock.now }, sleep: { clock.sleep($0) })
    for _ in 0..<5 { try await bucket.acquire(cost: 20) }
    try await bucket.acquire(cost: 20)  // 101st+ unit must wait ~60s for the window
    #expect(clock.totalSlept >= 59 && clock.totalSlept <= 61)
}

@Test func oversizedCostIsRejected() async {
    // `interactiveReserve: 0` — without it, the default (1,000) collapses
    // the background ceiling to 0 against this 100-unit window, and the
    // throw below would be caused by that collapse rather than by the
    // `101 > 100` units boundary this test is actually about (see
    // underCapacityNeverSleeps).
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 0)
    await #expect(throws: GmailError.self) {
        try await bucket.acquire(cost: 101)  // can never fit; must throw, not hang
    }
}

@Test func acquirersAreServedStrictlyInArrivalOrder() async throws {
    let clock = VirtualClock()
    // Three deviations from the brief's literal test, all discovered by
    // running this test 10+ times as instructed (per task instructions) —
    // full account in task-2-report.md:
    //
    // 1. `clock.sleep` is a plain synchronous call, so the brief's
    //    `sleep: { clock.sleep($0) }` never actually suspends the calling
    //    task — `big`'s whole acquire-fail-wait-retry-succeed cycle would
    //    complete in a fraction of a millisecond, well before `small` is
    //    even created. Verified empirically: with that literal wiring this
    //    test passed 15/15 runs against the *unfixed* recheck-loop
    //    QuotaBucket — no RED evidence at all.
    // 2. Wrapping `sleep` with a real delay, but still using the brief's
    //    fixed real 50ms pre-delay to assume "`big` has enqueued by now",
    //    is itself racy: `async let big`'s child task is not guaranteed to
    //    have been scheduled and reached its enqueue point within any fixed
    //    window. Verified empirically: this failed ~20-40% of runs.
    // 3. Even with a deterministic "big is enqueued" signal (below) instead
    //    of a timing guess, the brief's single-spend setup (one acquire(90))
    //    frees the *entire* window in one rollover, so `big` and `small`
    //    both become grantable inside the *same* drain() iteration and are
    //    `resume()`d back-to-back with no real time between them. Swift
    //    guarantees the order `resume()` is *called* (that part *is* FIFO),
    //    but not the order the two independently-resumed tasks actually run
    //    their post-resume code — that remainder is a genuine, unresolvable
    //    race. Verified empirically: ~20% of runs recorded `small`'s
    //    post-resume append landing fractions of a ms before `big`'s, even
    //    though `drain` resumed `big` first.
    //
    // Fix: stagger the setup into two spends 30s apart (below) instead of
    // one. That forces `big`'s grant and `small`'s grant into two *separate*
    // drain cycles, each behind its own real suspension — so `big`'s
    // post-resume code gets a full ~200ms head start to actually run before
    // `small` is granted at all, removing the race in (3). Combined with the
    // enqueue-confirmation signal (fixing (1)/(2)), ordering is then decided
    // by the real ~200ms gap between the two drain cycles, not by
    // unspecified scheduler behavior.
    let bigIsWaiting = OneShotSignal()
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 0,  // see underCapacityNeverSleeps
                              now: { clock.now }, sleep: { seconds in
        await bigIsWaiting.fire()
        try? await Task.sleep(for: .milliseconds(200))
        clock.sleep(seconds)
    })
    try await bucket.acquire(cost: 45)  // spend #1 — ages out of the window first
    clock.sleep(30)  // advance the virtual clock directly (not through the bucket): stagger the two spends by 30s
    try await bucket.acquire(cost: 45)  // spend #2 — window now nearly full (90/100), 30s "younger" than #1

    let order = LockedOrder()
    // Big request first — it doesn't fit yet (90 + 50 > 100). Small request
    // second — it WOULD fit against the current 90/100 spend if it could
    // jump the queue (90 + 10 == 100), but FIFO means it must wait behind
    // the big one.
    async let big: Void = {
        try await bucket.acquire(cost: 50)
        order.append("big")
    }()
    await bigIsWaiting.wait()  // deterministic: `big` has genuinely enqueued and is waiting
    async let small: Void = {
        try await bucket.acquire(cost: 10)
        order.append("small")
    }()
    _ = try await (big, small)
    #expect(order.values == ["big", "small"])
}

@Test func fifoStillRejectsOversizedCost() async throws {
    let clock = VirtualClock()
    let waiterIsQueued = OneShotSignal()
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 0,  // see underCapacityNeverSleeps
                              now: { clock.now }, sleep: { seconds in
        await waiterIsQueued.fire()
        clock.sleep(seconds)
    })
    try await bucket.acquire(cost: 100)  // saturate the window

    // A real waiter, queued behind the saturated window (won't be granted
    // until the window rolls over).
    async let waiter: Void = { _ = try? await bucket.acquire(cost: 1) }()
    await waiterIsQueued.wait()  // deterministic: the waiter has genuinely enqueued

    // An oversized request must fail fast — the cost guard is checked
    // unconditionally, before the waiter queue is ever consulted, so it must
    // never join the queue behind an already-waiting acquirer.
    await #expect(throws: GmailError.self) {
        try await bucket.acquire(cost: 101)
    }

    _ = await waiter  // let the queued waiter resolve so teardown doesn't hang
}

/// Thread-safe ordered event log for the FIFO test.
private final class LockedOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
    var values: [String] { lock.withLock { events } }
}

/// A fires-once/awaits-once gate. Used by the FIFO test to get a genuine
/// confirmation that `big` has reached its wait point, instead of guessing
/// a fixed real-time delay (which proved racy — see the doc comment on
/// `acquirersAreServedStrictlyInArrivalOrder`).
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
