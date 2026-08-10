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
    let bucket = QuotaBucket(unitsPerMinute: 100, now: { clock.now }, sleep: { clock.sleep($0) })
    for _ in 0..<5 { try await bucket.acquire(cost: 20) }  // exactly 100 units
    #expect(clock.totalSlept == 0)
}

@Test func overCapacityWaitsForWindowToRoll() async throws {
    let clock = VirtualClock()
    let bucket = QuotaBucket(unitsPerMinute: 100, now: { clock.now }, sleep: { clock.sleep($0) })
    for _ in 0..<5 { try await bucket.acquire(cost: 20) }
    try await bucket.acquire(cost: 20)  // 101st+ unit must wait ~60s for the window
    #expect(clock.totalSlept >= 59 && clock.totalSlept <= 61)
}

@Test func oversizedCostIsRejected() async {
    let bucket = QuotaBucket(unitsPerMinute: 100)
    await #expect(throws: GmailError.self) {
        try await bucket.acquire(cost: 101)  // can never fit; must throw, not hang
    }
}
