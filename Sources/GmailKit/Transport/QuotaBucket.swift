import Foundation

/// Gmail quota-unit costs per API method (spec §4.5, May-2026 pricing).
/// Defined for all of Hudson now; M1 only spends `getProfile`.
public enum GmailQuotaCost {
    public static let getProfile = 1
    public static let historyList = 2
    public static let messagesList = 5
    public static let messagesGet = 20
    public static let messagesSend = 100
}

/// Client-side rolling-minute rate limiter. Google enforces 6,000 quota
/// units/min/user (spec §4.5); we cap ourselves at 5,500 by default so a
/// second device or the Gmail app itself never pushes the account over.
/// `now`/`sleep` are injected so tests run on a virtual clock.
public actor QuotaBucket {
    private let unitsPerMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Spends inside the current 60s window, oldest first.
    private var spends: [(date: Date, cost: Int)] = []

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
    public func acquire(cost: Int) async throws {
        guard cost <= unitsPerMinute else {
            throw GmailError.invalidRequest(
                status: 0,
                message: "Quota cost \(cost) exceeds the per-minute budget of \(unitsPerMinute).")
        }
        while true {
            pruneExpiredSpends()
            let spent = spends.reduce(0) { $0 + $1.cost }
            if spent + cost <= unitsPerMinute {
                spends.append((now(), cost))
                return
            }
            // Sleep until the oldest spend leaves the window, then re-check.
            let oldest = spends[0].date
            let waitSeconds = max(60 - now().timeIntervalSince(oldest), 0.05)
            try await sleep(waitSeconds)
        }
    }

    private func pruneExpiredSpends() {
        let cutoff = now().addingTimeInterval(-60)
        spends.removeAll { $0.date <= cutoff }
    }
}
