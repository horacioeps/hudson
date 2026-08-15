import Foundation
import GRDB
import Testing
@testable import Store

// MARK: - Migration v11

/// The two columns the first-launch progress bar needs exist and start NULL —
/// "unknown" has to be representable, because it is the honest state before
/// Gmail's first list page returns.
@Test func v11AddsNullableBackfillProgressColumns() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)

    let record = try #require(try await db.account(email: "a@example.com"))
    #expect(record.backfillTotalEstimate == nil)
    #expect(record.backfillCountBaseline == nil)
}

// MARK: - Seeding

/// Both seeds land on the first write.
@Test func seedingRecordsTheEstimateAndTheBaseline() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)

    try await db.seedBackfillProgress(
        email: "a@example.com", totalEstimate: 1_240, countBaseline: 0)

    let record = try #require(try await db.account(email: "a@example.com"))
    #expect(record.backfillTotalEstimate == 1_240)
    #expect(record.backfillCountBaseline == 0)
}

/// The denominator is sticky IN SQL, not by caller discipline. Gmail returns a
/// slightly different `resultSizeEstimate` on later pages of the same listing;
/// letting one of those move the denominator would make the bar jump backwards
/// mid-download.
@Test func aLaterPagesEstimateCannotMoveTheDenominator() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)

    try await db.seedBackfillProgress(
        email: "a@example.com", totalEstimate: 1_240, countBaseline: 0)
    try await db.seedBackfillProgress(
        email: "a@example.com", totalEstimate: 999, countBaseline: 500)

    let record = try #require(try await db.account(email: "a@example.com"))
    #expect(record.backfillTotalEstimate == 1_240)
    #expect(record.backfillCountBaseline == 0)
}

/// Restarting is what lets the NEXT run re-seed. Without it, a re-list would
/// be measured against the previous run's denominator and read as already
/// done.
///
/// It resets the run state and forgets the seeds in ONE statement, and that
/// atomicity is the point: the seeds are sticky (`COALESCE`), so a crash
/// between a separate state-reset and seed-clear would leave a restarted run
/// permanently unable to re-seed itself.
@Test func restartingABackfillResetsStateAndSeedsTogether() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    try await db.seedBackfillProgress(
        email: "a@example.com", totalEstimate: 1_240, countBaseline: 0)
    try await db.updateBackfill(
        email: "a@example.com", state: "listing", pageToken: "tok", addedCount: 5)

    try await db.restartBackfill(email: "a@example.com")

    let record = try #require(try await db.account(email: "a@example.com"))
    #expect(record.backfillState == "pending")
    #expect(record.backfillPageToken == nil)
    #expect(record.backfillTotalEstimate == nil)
    #expect(record.backfillCountBaseline == nil)
}

/// An unseeded run is NOT a first download. `nil` means "we don't know yet";
/// a genuinely fresh account is seeded with an explicit `0`. Conflating the
/// two let the footer quote a stored count from a mailbox that was already
/// full.
@Test func anUnseededRunIsNeitherSeededNorAFirstDownload() {
    let unseeded = BackfillProgress(
        state: "pending", stored: 880, totalEstimate: nil, countBaseline: nil)
    #expect(!unseeded.isSeeded)
    #expect(!unseeded.isFirstDownload)

    let fresh = BackfillProgress(
        state: "listing", stored: 0, totalEstimate: 100, countBaseline: 0)
    #expect(fresh.isSeeded)
    #expect(fresh.isFirstDownload)
}

/// A `nil` estimate — Gmail may omit the field — must be storable as "unknown"
/// rather than coerced to a number the UI would then divide by.
@Test func aMissingEstimateStaysNil() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)

    try await db.seedBackfillProgress(
        email: "a@example.com", totalEstimate: nil, countBaseline: 3)

    let record = try #require(try await db.account(email: "a@example.com"))
    #expect(record.backfillTotalEstimate == nil)
    #expect(record.backfillCountBaseline == 3)
}

// MARK: - Windowed count

/// The numerator counts only inside the sync window, matching the `after:`
/// filter the backfill itself lists with. Counting a wider set than the run
/// lists would make the bar overshoot its denominator.
@Test func messageCountRespectsTheWindowBoundary() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    try await seedMessage(db, id: "old", internalDate: 1_000)
    try await seedMessage(db, id: "new", internalDate: 9_000)

    #expect(try await db.messageCount(account: "a@example.com", since: 0) == 2)
    #expect(try await db.messageCount(account: "a@example.com", since: 5_000) == 1)
    #expect(try await db.messageCount(account: "a@example.com", since: 20_000) == 0)
}

/// Scoped per account, like every other read in Store.
@Test func messageCountIsScopedToOneAccount() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    try await db.upsertAccount(email: "b@example.com", clientID: "id", consentedAt: .now)
    try await seedMessage(db, id: "m1", internalDate: 9_000)
    try await seedMessage(db, id: "m2", internalDate: 9_000, account: "b@example.com")

    #expect(try await db.messageCount(account: "a@example.com", since: 0) == 1)
}

// MARK: - BackfillProgress semantics

/// Completion is state-driven. A page whose messages 404 between `list` and
/// `get` is skipped without incrementing the stored count, so an arithmetic
/// completion test would hang below 100% forever on a mailbox with deleted mail.
@Test func isRunningFollowsStateNotArithmetic() {
    let short = BackfillProgress(
        state: "listing", stored: 1_240, totalEstimate: 1_240, countBaseline: 0)
    #expect(short.isRunning)

    let done = BackfillProgress(
        state: "complete", stored: 3, totalEstimate: 1_240, countBaseline: 0)
    #expect(!done.isRunning)
}

/// A zero baseline is a genuine first download; anything higher means the run
/// is re-listing mail already on disk, which gets no bar.
@Test func firstDownloadIsDistinguishedFromARelist() {
    let fresh = BackfillProgress(
        state: "listing", stored: 10, totalEstimate: 100, countBaseline: 0)
    #expect(fresh.isFirstDownload)

    let relist = BackfillProgress(
        state: "listing", stored: 900, totalEstimate: 1_000, countBaseline: 880)
    #expect(!relist.isFirstDownload)

    // Not yet seeded is NOT a first download — see
    // `anUnseededRunIsNeitherSeededNorAFirstDownload`.
    let unseeded = BackfillProgress(
        state: "pending", stored: 0, totalEstimate: nil, countBaseline: nil)
    #expect(!unseeded.isFirstDownload)
}

// MARK: - Observation

/// The observation reports live persisted truth: state, the windowed count,
/// and both seeds.
@Test func observationReportsStateCountAndSeeds() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    try await seedMessage(db, id: "m1", internalDate: 9_000)
    try await db.seedBackfillProgress(
        email: "a@example.com", totalEstimate: 50, countBaseline: 0)
    try await db.updateBackfill(
        email: "a@example.com", state: "listing", pageToken: "t", addedCount: 1)

    var iterator = db.observeBackfillProgress(account: "a@example.com", windowStart: 0)
        .makeAsyncIterator()
    let first = try #require(try await iterator.next())

    #expect(first.state == "listing")
    #expect(first.stored == 1)
    #expect(first.totalEstimate == 50)
    #expect(first.countBaseline == 0)
    #expect(first.isRunning)
}

/// A disconnected account (row gone mid-observation) reads as "nothing to do"
/// rather than throwing — the subscription is torn down moments later either
/// way, and a failed stream is of no use to the UI.
@Test func observationTreatsAMissingAccountAsComplete() async throws {
    let db = try HudsonDatabase.inMemory()

    var iterator = db.observeBackfillProgress(account: "gone@example.com", windowStart: 0)
        .makeAsyncIterator()
    let first = try #require(try await iterator.next())

    #expect(first.state == "complete")
    #expect(!first.isRunning)
    #expect(first.stored == 0)
}

// MARK: - Support

/// Minimal `messages` row — enough for the windowed count, without dragging in
/// the full snapshot-apply path.
private func seedMessage(
    _ db: HudsonDatabase, id: String, internalDate: Int64, account: String = "a@example.com"
) async throws {
    try await db.writer.write { database in
        try database.execute(
            sql: """
                INSERT INTO messages
                    (account_email, id, thread_id, history_id, internal_date)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [account, id, "t-\(id)", 1, internalDate])
    }
}
