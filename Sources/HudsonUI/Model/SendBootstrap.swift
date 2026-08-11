import Foundation
import GmailKit
import Outbox
import Store

/// Builds a `SendService` from whatever's in the Keychain for `account` —
/// the Keychain→`GmailClient` half of this is a deliberate duplicate of
/// `SyncBootstrap.makeStack`'s wiring (same session/client construction),
/// not a refactor into one shared helper: `SendService` and `SyncStack`
/// serve different callers (`ComposerModel` vs. `AppModel.syncNow()`) that
/// should stay free to evolve their own credential handling, and the
/// duplicated block is a handful of lines.
enum SendBootstrap {
    /// Returns `nil` — NEVER throws — whenever a credential is missing, so
    /// `ComposerModel.send()` can show a friendly "connect an account"
    /// banner instead of crashing. Same contract as `SyncBootstrap.makeStack`.
    ///
    /// `store` defaults to the real Keychain in production (every existing
    /// call site keeps working unchanged) but is an injectable seam so
    /// tests can pass `InMemoryTokenStore()` instead — CI must never touch
    /// a real keychain (spec §6.3, same rule `GmailKitTests` already
    /// follows for every other `TokenStore` consumer).
    static func makeService(
        database: HudsonDatabase, account: AccountRecord, store: any TokenStore = KeychainTokenStore()
    ) -> SendService? {
        guard let clientSecret = try? store.clientSecret(account: account.email) else { return nil }
        let session = AccountSession(
            account: account.email,
            oauth: OAuthClient(
                credentials: OAuthCredentials(clientID: account.clientID, clientSecret: clientSecret),
                transport: URLSessionTransport()),
            store: store)
        let client = GmailClient(session: session, transport: URLSessionTransport(), quota: QuotaBucket())
        return SendService(api: client, database: database, account: account.email)
    }
}
