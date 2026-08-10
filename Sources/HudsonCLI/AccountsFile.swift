import Foundation
import GmailKit

/// One connected Gmail account. Deliberately free of secrets: the client
/// secret and tokens live in the Keychain (spec §6.3). M2 migrates this
/// file into the GRDB `accounts` table.
struct StoredAccount: Codable {
    var email: String
    var clientID: String
    /// When the user granted consent — powers the "app still in Testing?"
    /// diagnostic when a refresh fails within ~7 days (spec §6.1).
    var consentedAt: Date
}

/// JSON persistence for connected accounts at
/// `~/Library/Application Support/Hudson/accounts.json`.
enum AccountsFile {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hudson/accounts.json")
    }

    static func load() throws -> [StoredAccount] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode([StoredAccount].self, from: data)
    }

    static func save(_ accounts: [StoredAccount]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: url)
    }

    /// The account CLI commands operate on. Multi-account selection arrives
    /// with the M2 data model; M1 uses the first (only) account.
    static func primary() throws -> StoredAccount {
        guard let account = try load().first else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        return account
    }
}
