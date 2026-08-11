import Foundation
import GmailKit
import Store
import Testing
@testable import HudsonUI

/// Mirrors `SyncBootstrap`'s "no creds" contract exactly: an account with
/// nothing saved in its token store must come back `nil` — never throw,
/// never crash — so `ComposerModel.send()` can show a "connect an account"
/// banner instead of forcing a hard failure. Injects `InMemoryTokenStore`
/// via Task 1's seam so this never touches the real macOS Keychain — same
/// rule `AppModelTests.syncNowWithNoAccountSurfacesConnectBanner` documents
/// for `SyncBootstrap`, and the one every `GmailKitTests` `TokenStore`
/// consumer already follows.
@Test func makeServiceWithNoStoredCredentialsReturnsNil() async throws {
    let db = try HudsonDatabase.inMemory()
    // `AccountRecord`'s memberwise init is package-internal, so — exactly
    // like production callers — fetch a real record back out of the store
    // rather than hand-construct one.
    let email = "sendbootstrap-notoken-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client-id", consentedAt: Date())
    let account = try #require(try await db.account(email: email))

    let service = SendBootstrap.makeService(database: db, account: account, store: InMemoryTokenStore())

    #expect(service == nil)
}

/// The counterpart happy path: with a client secret present in the token
/// store, `makeService` must build a real `SendService` rather than `nil`.
/// Without this, a regression that made `clientSecret` throw (or otherwise
/// fail) unconditionally would be indistinguishable from the correct
/// "no creds" behavior above — both yield `nil` — and would go undetected.
@Test func makeServiceWithStoredCredentialsReturnsService() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "sendbootstrap-hastoken-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client-id", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let store = InMemoryTokenStore()
    try store.saveClientSecret("shh", account: email)

    let service = SendBootstrap.makeService(database: db, account: account, store: store)

    #expect(service != nil)
}
