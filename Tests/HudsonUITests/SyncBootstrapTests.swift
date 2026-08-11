import Foundation
import GmailKit
import Store
import Testing
@testable import HudsonUI

/// Mirrors `SendBootstrapTests`' "no creds" contract exactly, for
/// `SyncBootstrap.makeHydrator` — the closure-builder `AppModel` uses to
/// give `ThreadModel` its on-demand body fetch. An account with nothing
/// saved in its token store must come back `nil` — never throw, never
/// crash — so `ThreadModel` falls back to exactly today's local-only
/// behavior (the `--demo` mailbox, and any account before `hudson auth`,
/// both hit this path). Injects `InMemoryTokenStore` so this never touches
/// the real macOS Keychain (spec §6.3).
@Test func makeHydratorWithNoStoredCredentialsReturnsNil() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "syncbootstrap-notoken-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client-id", consentedAt: Date())
    let account = try #require(try await db.account(email: email))

    let hydrator = SyncBootstrap.makeHydrator(database: db, account: account, store: InMemoryTokenStore())

    #expect(hydrator == nil)
}

/// The counterpart happy path: with a client secret present in the token
/// store, `makeHydrator` must build a real closure rather than `nil`.
/// Without this, a regression that made `clientSecret` throw (or otherwise
/// fail) unconditionally would be indistinguishable from the correct
/// "no creds" behavior above — both yield `nil` — and would go undetected.
/// Mirrors `SendBootstrapTests.makeServiceWithStoredCredentialsReturnsService`
/// in scope: it checks the closure itself gets built, not a live network
/// round-trip (that's `HydrationTests`' `SyncEngine.hydrate` coverage).
@Test func makeHydratorWithStoredCredentialsReturnsAClosure() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "syncbootstrap-hastoken-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client-id", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let store = InMemoryTokenStore()
    try store.saveClientSecret("shh", account: email)

    let hydrator = SyncBootstrap.makeHydrator(database: db, account: account, store: store)

    #expect(hydrator != nil)
}
