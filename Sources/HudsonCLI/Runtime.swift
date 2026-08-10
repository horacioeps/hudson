import Foundation
import GmailKit
import Store
import SyncEngine

/// `SyncEngine.SyncEngine` (module-qualified) fails to resolve: the actor's
/// own name shadows its declaring module, so Swift can't disambiguate the
/// qualified form. Reference the (unambiguous, unqualified) type instead.
typealias Engine = SyncEngine

/// Wires the CLI's object graph for read-only commands (list, show, sync --status).
/// Opens only the database and loads the primary account — never touches the Keychain
/// or builds a network client.
struct LocalRuntime {
    let database: HudsonDatabase
    let account: AccountRecord

    /// Opens the store with the given database URL, runs migration if needed, and loads
    /// the primary account. Throws `GmailError.auth` if no account is connected.
    static func local(databaseURL: URL) async throws -> LocalRuntime {
        let database = try HudsonDatabase.open(at: databaseURL)
        try await AccountsMigration.runIfNeeded(database: database)
        guard let account = try await database.primaryAccount() else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        return LocalRuntime(database: database, account: account)
    }

    /// Opens the store at the default location, runs migration if needed, and loads
    /// the primary account. Throws `GmailError.auth` if no account is connected.
    static func local() async throws -> LocalRuntime {
        return try await local(databaseURL: HudsonPaths.databaseURL)
    }
}

/// Wires the CLI's object graph for commands that need a connected account and network access.
struct Runtime {
    let database: HudsonDatabase
    let account: AccountRecord
    let client: GmailClient
    let engine: Engine

    /// Opens the store, migrates legacy accounts.json if present, and builds
    /// the client stack for the primary account.
    static func bootstrap() async throws -> Runtime {
        let database = try HudsonDatabase.open(at: HudsonPaths.databaseURL)
        try await AccountsMigration.runIfNeeded(database: database)
        guard let account = try await database.primaryAccount() else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        let store = KeychainTokenStore()
        guard let clientSecret = try store.clientSecret(account: account.email) else {
            throw GmailError.auth("Keychain has no client secret — run `hudson auth` again.")
        }
        let session = AccountSession(
            account: account.email,
            oauth: OAuthClient(
                credentials: OAuthCredentials(
                    clientID: account.clientID, clientSecret: clientSecret),
                transport: URLSessionTransport()),
            store: store)
        let client = GmailClient(
            session: session, transport: URLSessionTransport(), quota: QuotaBucket())
        let engine = Engine(
            api: client, database: database, account: account.email)
        return Runtime(database: database, account: account, client: client, engine: engine)
    }
}
