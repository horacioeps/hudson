import Foundation
import GmailKit
import Store
import SyncEngine

/// `SyncEngine.SyncEngine` (module-qualified) fails to resolve: the actor's
/// own name shadows its declaring module, so Swift can't disambiguate the
/// qualified form. Reference the (unambiguous, unqualified) type instead —
/// same issue, same fix, as `HudsonCLI/Runtime.swift`'s identical `typealias`.
typealias Engine = SyncEngine

/// The network stack `AppModel.syncNow()` needs for one best-effort sync
/// pass: poll history/backfill/hydrate (`engine`), then drain the local
/// triage queue to Gmail (`flusher`).
struct SyncStack {
    let engine: Engine
    let flusher: MutationFlusher
}

/// Builds `SyncStack` from whatever's in the Keychain for `account` —
/// mirrors `HudsonCLI/Runtime.bootstrap()`'s wiring exactly (same session/
/// client/engine/flusher shape). Duplicated rather than shared: `HudsonUI`
/// cannot depend on `HudsonCLI` (dependencies only run executable ->
/// library, never the other way), so the handful of lines that actually
/// construct the stack live here too, as a small, UI-side seam.
enum SyncBootstrap {
    /// Returns `nil` — NEVER throws — whenever a credential is missing, so
    /// `AppModel.syncNow()` can show a friendly "run `hudson auth`" banner
    /// instead of crashing. This is the COMMON case for `--demo` and any
    /// first launch before the user has authenticated in Terminal.
    static func makeStack(database: HudsonDatabase, account: AccountRecord) -> SyncStack? {
        let store = KeychainTokenStore()
        guard let clientSecret = try? store.clientSecret(account: account.email) else { return nil }
        let session = AccountSession(
            account: account.email,
            oauth: OAuthClient(
                credentials: OAuthCredentials(clientID: account.clientID, clientSecret: clientSecret),
                transport: URLSessionTransport()),
            store: store)
        let client = GmailClient(session: session, transport: URLSessionTransport(), quota: QuotaBucket())
        let engine = Engine(api: client, database: database, account: account.email)
        let flusher = MutationFlusher(api: client, database: database, account: account.email)
        return SyncStack(engine: engine, flusher: flusher)
    }
}
