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

/// "Disconnect account" (Task 5): removing the account row is what makes
/// `primaryAccount()` forget it ever existed — the Store half of "Hudson
/// forgets this account on this Mac" (the other half is
/// `KeychainTokenStore.deleteAll`, covered in `TokenStoreTests`).
@Test func deleteAccountMakesPrimaryAccountReturnNil() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "a@b.c", clientID: "cid", consentedAt: .now)

    try await database.deleteAccount(email: "a@b.c")

    #expect(try await database.primaryAccount() == nil)
    #expect(try await database.account(email: "a@b.c") == nil)
}

/// Deleting one account must never touch a different one — mirrors
/// `TokenStore.deleteAll`'s own "one account only" contract on the Keychain
/// side, so a multi-account Mac never loses the wrong account's data.
@Test func deleteAccountLeavesOtherAccountsUntouched() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "a@b.c", clientID: "cid", consentedAt: .now)
    try await database.upsertAccount(email: "other@b.c", clientID: "cid2", consentedAt: .now)

    try await database.deleteAccount(email: "a@b.c")

    #expect(try await database.account(email: "a@b.c") == nil)
    #expect(try await database.account(email: "other@b.c") != nil)
}
