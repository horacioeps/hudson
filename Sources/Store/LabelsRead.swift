import GRDB

/// One label row for the sidebar — user-created or Gmail system label. The
/// `labels` table is exactly `(account_email, id, name)` — no stored `type`
/// column (`Migrations.swift`'s v1 migration) — so distinguishing system vs.
/// user labels (e.g. `INBOX`, `CATEGORY_*`) is the caller's job, done by
/// matching `id` against Gmail's known system-label ids/prefixes, not by a
/// column here.
public struct LabelRecord: Sendable, Equatable {
    public let id: String
    public let name: String
}

extension HudsonDatabase {
    /// All of one account's labels, alphabetical by name — the sidebar's
    /// label list.
    public func labels(account: String) async throws -> [LabelRecord] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, name FROM labels WHERE account_email = ? ORDER BY name",
                arguments: [account])
            return rows.map { LabelRecord(id: $0["id"], name: $0["name"]) }
        }
    }
}
