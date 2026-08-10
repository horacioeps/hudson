import Foundation
import Testing
@testable import Store

@Test func accountRoundTrips() async throws {
    let database = try HudsonDatabase.inMemory()
    let consented = Date(timeIntervalSinceReferenceDate: 776_000_000)
    try await database.upsertAccount(email: "a@b.c", clientID: "cid", consentedAt: consented)
    let record = try #require(try await database.account(email: "a@b.c"))
    #expect(record.clientID == "cid")
    #expect(abs(record.consentedAt.timeIntervalSince(consented)) < 0.001)
    #expect(record.backfillState == "pending")
}

@Test func backfillProgressPersists() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "a@b.c", clientID: "cid", consentedAt: .now)
    try await database.updateBackfill(
        email: "a@b.c", state: "listing", pageToken: "page-2", addedCount: 150)
    let record = try #require(try await database.account(email: "a@b.c"))
    #expect(record.backfillState == "listing")
    #expect(record.backfillPageToken == "page-2")
    #expect(record.backfilledCount == 150)
}
