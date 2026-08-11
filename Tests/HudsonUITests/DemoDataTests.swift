import Store
import Testing
@testable import HudsonUI

@Test func demoSeedPopulatesInboxAcrossSplits() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")

    let all = try await db.inboxThreads(account: "you@hudson.app", split: nil, limit: 100)
    #expect(all.count >= 20)

    let splits = Set(all.map(\.splitKey))
    #expect(splits.contains("important"))
    #expect(all.contains { $0.unread })
    #expect(all.contains { $0.hasAttachment })
}

/// `AppModel.demo()` opens the fixed-path temp demo database (seeding it
/// with `DemoData` on first open) and returns a usable model — the same
/// path `--demo`/`HUDSON_DEMO=1` wires up in `HudsonApp`/`RootView`. Runs
/// against the real on-disk temp file (not an in-memory DB) since that's
/// exactly what `demo()` opens; the empty-check guard makes this safe to
/// run repeatedly without duplicating the seed.
@MainActor
@Test func appModelDemoYieldsAModelWithAnAccount() async throws {
    let model = try await AppModel.demo()
    #expect(model.account != nil)
    #expect(model.account?.email == AppModel.demoAccount)

    let threads = try await model.database.inboxThreads(
        account: AppModel.demoAccount, split: nil, limit: 100)
    #expect(threads.count >= 20)
}
