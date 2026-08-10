import Foundation
import GRDB

/// The one handle to Hudson's local SQLite store. All writes flow through
/// GRDB's single writer queue; reads use snapshots. Actor code must use the
/// async GRDB APIs only (spec §4.6) — synchronous write/read from an actor
/// blocks a cooperative-pool thread.
public struct HudsonDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the store at `url` and migrates to the
    /// current schema. The parent directory is created if missing, and is
    /// excluded from Time Machine (spec §3.3: the data dir is excluded from
    /// backup by default). Best-effort: a backup-exclusion failure must not
    /// block opening the store, so it's `try?` — defense-in-depth, not a
    /// hard requirement.
    public static func open(at url: URL) throws -> HudsonDatabase {
        var dirURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dirURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirURL.setResourceValues(values)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator.migrate(pool)
        return HudsonDatabase(writer: pool)
    }

    /// In-memory store for tests — same schema, no disk.
    public static func inMemory() throws -> HudsonDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue)
        return HudsonDatabase(writer: queue)
    }
}
