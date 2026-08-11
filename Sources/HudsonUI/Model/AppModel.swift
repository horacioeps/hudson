import Foundation
import Store

/// The root of the app's object graph. Owns the open database and the active
/// account; child models (inbox, thread, search, palette) hang off it in later
/// tasks. `@MainActor` because every view model in Hudson is main-actor —
/// SwiftUI reads them on the main thread and Store access is via async APIs, so
/// nothing here ever blocks a cooperative-pool thread.
@MainActor
@Observable
public final class AppModel {
    public let database: HudsonDatabase
    public private(set) var account: AccountRecord?

    /// Opens the store at `databaseURL` and loads the primary account. Never
    /// touches the Keychain or the network — the app is read-and-triage until
    /// the user explicitly hits "Sync now" (added in a later task).
    public init(databaseURL: URL) async throws {
        self.database = try HudsonDatabase.open(at: databaseURL)
        self.account = try await database.primaryAccount()
    }

    /// Direct-injection initializer for tests and previews (seeded in-memory DB).
    public init(database: HudsonDatabase, account: AccountRecord?) {
        self.database = database
        self.account = account
    }

    /// The demo mailbox's account — matches `DemoData.seed`'s default so
    /// `--demo` reads back exactly what it seeded.
    public static let demoAccount = "you@hudson.app"

    /// Opens (creating if needed) the fixed-path demo database and seeds it
    /// with `DemoData` on first open — guarded on `inboxThreads` being
    /// empty so a relaunch of `--demo`/`HUDSON_DEMO=1` never re-seeds (and
    /// never duplicates) an already-seeded demo mailbox. Used for
    /// screenshots and manual QA without ever touching a real mailbox.
    public static func demo() async throws -> AppModel {
        let url = FileManager.default.temporaryDirectory.appending(path: "hudson-demo.sqlite")
        let database = try HudsonDatabase.open(at: url)
        let existing = try await database.inboxThreads(account: demoAccount, split: nil, limit: 1)
        if existing.isEmpty {
            try await DemoData.seed(into: database, account: demoAccount)
        }
        let account = try await database.primaryAccount()
        return AppModel(database: database, account: account)
    }
}
