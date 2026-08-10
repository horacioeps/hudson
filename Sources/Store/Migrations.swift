import GRDB

/// Schema history. Migrations are append-only: never edit a registered
/// migration after it ships — add a new one.
let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("v1") { db in
        try db.create(table: "accounts") { t in
            t.column("email", .text).primaryKey()
            t.column("client_id", .text).notNull()
            // Seconds since reference date (Foundation's default Date coding —
            // matches what M1's accounts.json wrote; see AccountsFileMigration).
            t.column("consented_at", .double).notNull()
            t.column("history_cursor", .integer)                // last applied historyId
            t.column("backfill_state", .text).notNull().defaults(to: "pending")
            t.column("backfill_page_token", .text)              // resumable list cursor
            t.column("backfilled_count", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "threads") { t in
            t.column("account_email", .text).notNull()
            t.column("id", .text).notNull()
            t.column("last_message_at", .integer)               // ms since epoch
            t.primaryKey(["account_email", "id"])
        }
        try db.create(table: "messages") { t in
            t.column("account_email", .text).notNull()
            t.column("id", .text).notNull()
            t.column("thread_id", .text).notNull()
            t.column("history_id", .integer).notNull()          // §4.2 version guard
            t.column("internal_date", .integer).notNull()       // ms since epoch
            t.column("from_line", .text).notNull().defaults(to: "")
            t.column("to_line", .text).notNull().defaults(to: "")
            t.column("subject", .text).notNull().defaults(to: "")
            t.column("snippet", .text).notNull().defaults(to: "")
            t.column("has_body", .boolean).notNull().defaults(to: false)
            t.primaryKey(["account_email", "id"])
        }
        try db.create(
            indexOn: "messages", columns: ["account_email", "internal_date"])
        try db.create(table: "message_bodies") { t in
            t.column("account_email", .text).notNull()
            t.column("message_id", .text).notNull()
            t.column("raw_html", .blob)                         // opaque bytes, never interpreted
            t.column("plain_text", .text).notNull()
            t.column("sanitizer_version", .integer).notNull()
            t.column("cid_references", .text).notNull().defaults(to: "[]")   // JSON array
            t.column("remote_urls", .text).notNull().defaults(to: "[]")      // JSON array
            t.primaryKey(["account_email", "message_id"])
            t.foreignKey(["account_email", "message_id"],
                         references: "messages", columns: ["account_email", "id"],
                         onDelete: .cascade)
        }
        try db.create(table: "labels") { t in
            t.column("account_email", .text).notNull()
            t.column("id", .text).notNull()
            t.column("name", .text).notNull()
            t.primaryKey(["account_email", "id"])
        }
        try db.create(table: "message_labels") { t in
            t.column("account_email", .text).notNull()
            t.column("message_id", .text).notNull()
            t.column("label_id", .text).notNull()
            t.primaryKey(["account_email", "message_id", "label_id"])
            t.foreignKey(["account_email", "message_id"],
                         references: "messages", columns: ["account_email", "id"],
                         onDelete: .cascade)
        }
        try db.create(table: "tombstones") { t in
            t.column("account_email", .text).notNull()
            t.column("message_id", .text).notNull()
            t.primaryKey(["account_email", "message_id"])
        }
    }

    migrator.registerMigration("v2") { db in
        try db.create(table: "mutation_queue") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("account_email", .text).notNull()
            t.column("message_id", .text).notNull()
            t.column("label_id", .text).notNull()
            t.column("op", .text).notNull()               // 'add' | 'remove'
            t.column("state", .text).notNull().defaults(to: "pending")  // 'pending' | 'in_flight'
            t.column("enqueued_at", .integer).notNull()   // ms since epoch
            t.column("expected_history_id", .integer)     // set once in_flight; retirement gate
        }
        // At most one live delta per (account, message, label): a later opposite
        // op supersedes rather than stacks (Task 2 handles the replace).
        try db.create(
            index: "mutation_queue_unique_live",
            on: "mutation_queue", columns: ["account_email", "message_id", "label_id"],
            unique: true)
        try db.create(
            index: "mutation_queue_drain",
            on: "mutation_queue", columns: ["account_email", "state", "id"])
    }

    return migrator
}()
