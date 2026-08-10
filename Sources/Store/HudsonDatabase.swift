import Foundation
import GRDB

/// The one handle to Hudson's local SQLite store. All writes flow through
/// GRDB's single writer queue; reads use snapshots. Actor code must use the
/// async GRDB APIs only (spec §4.6) — synchronous write/read from an actor
/// blocks a cooperative-pool thread.
public struct HudsonDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Tuned configuration (spec §4.6 + architecture M3). WAL + synchronous=NORMAL
    /// is safe because Gmail is the source of truth — a lost last commit on power
    /// failure re-syncs. cache_size/mmap_size/busy_timeout keep triage enqueues
    /// off the fsync path. WAL only applies to on-disk pools; the in-memory test
    /// queue silently keeps its default journal.
    static func tunedConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -20000")   // ~20 MB
            try db.execute(sql: "PRAGMA mmap_size = 268435456")  // 256 MB
        }
        return configuration
    }

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
        let pool = try DatabasePool(path: url.path, configuration: Self.tunedConfiguration())
        try migrator.migrate(pool)
        return HudsonDatabase(writer: pool)
    }

    /// In-memory store for tests — same schema, no disk.
    public static func inMemory() throws -> HudsonDatabase {
        let queue = try DatabaseQueue(configuration: Self.tunedConfiguration())
        try migrator.migrate(queue)
        return HudsonDatabase(writer: queue)
    }
}
