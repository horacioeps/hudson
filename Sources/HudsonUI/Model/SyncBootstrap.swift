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
    ///
    /// `store` defaults to the real Keychain in production (every existing
    /// call site keeps working unchanged) but is an injectable seam — same
    /// shape as `SendBootstrap.makeService`'s — so tests (and
    /// `makeHydrator` below) can pass `InMemoryTokenStore()` instead; CI
    /// must never touch a real keychain (spec §6.3).
    static func makeStack(
        database: HudsonDatabase, account: AccountRecord, store: any TokenStore = KeychainTokenStore()
    ) -> SyncStack? {
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

    /// Builds `ThreadModel`'s on-demand body-fetch closure: the reading
    /// pane's fix for a message that's expanded but hasn't been reached yet
    /// by the background `SyncEngine.hydrateBodies()` batch (capped at
    /// 25/pass — a large mailbox's backfill can starve it for a long time).
    ///
    /// Reuses `makeStack` for the identical KeychainTokenStore ->
    /// OAuthClient -> GmailClient -> SyncEngine wiring `syncNow()`/
    /// `startAutoSync` already use (one source of truth for that
    /// construction), then captures ONLY its `engine` — built exactly
    /// ONCE, here, not per call. Every invocation of the returned closure
    /// just calls `engine.hydrate(messageID:)` on that same actor; nothing
    /// about the network stack is rebuilt on the reading pane's hot path.
    ///
    /// Returns `nil` under the same conditions `makeStack` does (no stored
    /// credentials — `--demo`, or any account before `hudson auth`), so
    /// `ThreadModel` gets exactly today's local-only behavior: no fetch, a
    /// body-less message stays uncached until the next background pass.
    /// The returned closure itself never throws: a failed on-demand fetch
    /// (network down, rate-limited, ...) is swallowed to `false` via
    /// `try?` — the SAME "leave it uncached, the next expand/re-emit
    /// retries" contract a local cache miss already has, so the reading
    /// pane never needs to distinguish "still hydrating" from "just failed
    /// once."
    static func makeHydrator(
        database: HudsonDatabase, account: AccountRecord, store: any TokenStore = KeychainTokenStore()
    ) -> (@Sendable (String) async -> Bool)? {
        guard let stack = makeStack(database: database, account: account, store: store) else { return nil }
        let engine = stack.engine
        return { id in
            (try? await engine.hydrate(messageID: id)) ?? false
        }
    }
}
