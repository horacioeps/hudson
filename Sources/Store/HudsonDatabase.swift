import Foundation
import GRDB

/// The one handle to Hudson's local SQLite store. All writes flow through
/// GRDB's single writer queue; reads use snapshots. Actor code must use the
/// async GRDB APIs only (spec §4.6) — synchronous write/read from an actor
/// blocks a cooperative-pool thread.
public struct HudsonDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the store at `url` and migrates to the
    /// current schema. The parent directory is created if missing.
    public static func open(at url: URL) throws -> HudsonDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
