import Foundation

extension HudsonDatabase {
    /// The default on-disk store location, shared by the CLI and the app so
    /// both read and write the SAME mailbox: `~/Library/Application
    /// Support/Hudson/hudson.sqlite`. Kept here (not in the CLI) because the
    /// UI target needs it too, and duplicating the path in two targets is how
    /// they silently drift onto two different databases.
    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hudson/hudson.sqlite")
    }
}
