import Foundation
import Store
import Testing
@testable import HudsonUI

/// Mirrors `SyncBootstrap`'s "no creds" contract exactly: an account with
/// nothing saved in the Keychain must come back `nil` — never throw, never
/// crash — so `ComposerModel.send()` can show a "connect an account" banner
/// instead of forcing a hard failure. A fresh, randomized email guarantees
/// this test never collides with a real Keychain item a developer's machine
/// might actually hold (Task 1 has no injectable Keychain seam yet — the
/// same constraint `SyncBootstrap` itself operates under).
@Test func makeServiceWithNoStoredCredentialsReturnsNil() async throws {
    let db = try HudsonDatabase.inMemory()
    // `AccountRecord`'s memberwise init is package-internal, so — exactly
    // like production callers — fetch a real record back out of the store
    // rather than hand-construct one.
    let email = "sendbootstrap-notoken-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client-id", consentedAt: Date())
    let account = try #require(try await db.account(email: email))

    let service = SendBootstrap.makeService(database: db, account: account)

    #expect(service == nil)
}
