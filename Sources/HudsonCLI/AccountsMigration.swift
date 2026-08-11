import Foundation
import Store

/// Filesystem locations the CLI uses.
enum HudsonPaths {
    /// The SQLite store, shared with the app — see `HudsonDatabase.defaultDatabaseURL`.
    static var databaseURL: URL { HudsonDatabase.defaultDatabaseURL }
}

/// One-time import of M1's accounts.json into the database.
/// Thin wrapper around AccountsImport (in Store) with the standard file path.
enum AccountsMigration {
    /// Runs the legacy-file import if needed (file exists, table empty).
    /// Atomic: either all accounts import or none, so crashes leave the table in a
    /// clean state for retry.
    static func runIfNeeded(database: HudsonDatabase) async throws {
        _ = try await AccountsImport.importLegacyFile(
            at: AccountsFile.url, database: database)
    }
}
