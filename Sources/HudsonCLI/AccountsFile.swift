import Foundation

/// LEGACY (M1): superseded by the accounts table; kept only so AccountsMigration can read old installs. Do not add new callers.
enum AccountsFile {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hudson/accounts.json")
    }
}
