import Foundation
import Store

/// Filesystem locations the CLI uses.
enum HudsonPaths {
    /// The SQLite store: ~/Library/Application Support/Hudson/hudson.sqlite
    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hudson/hudson.sqlite")
    }
}

/// One-time import of M1's accounts.json into the database. M1 wrote dates
/// with JSONEncoder's DEFAULT strategy (seconds since the reference date, a
/// bare Double) — decode with the default strategy, never .iso8601.
enum AccountsMigration {
    static func runIfNeeded(database: HudsonDatabase) async throws {
        let legacyURL = AccountsFile.url
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard try await database.primaryAccount() == nil else { return }

        let legacy = try AccountsFile.load()
        for account in legacy {
            try await database.upsertAccount(
                email: account.email, clientID: account.clientID,
                consentedAt: account.consentedAt)
        }
        try FileManager.default.moveItem(
            at: legacyURL,
            to: legacyURL.deletingLastPathComponent().appending(path: "accounts.json.migrated"))
    }
}
