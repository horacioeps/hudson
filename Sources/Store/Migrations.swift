import GRDB

/// The one-time bulk build that seeds `thread_rollup`, `message_seq`, and
/// `fts_messages` from whatever's already in `messages` / `message_bodies` /
/// `message_labels`. Run exactly once, by migration `v3`, against
/// whatever's already synced (so a 100k-message install doesn't open to an
/// empty inbox) — the query layer's incremental maintenance keeps these
/// tables current afterward. Extracted to a named function (rather than
/// inlined raw SQL in the migration closure) so `QueryLayerMigrationTests`
/// can exercise the exact same statements against seeded data: this is raw
/// SQL with no compiler type-checking, and a subtle bug here would silently
/// mis-populate every existing install's inbox.
func runQueryLayerBulkBuild(_ db: Database) throws {
    try db.execute(sql: """
        INSERT INTO thread_rollup (account_email, thread_id, last_message_at, last_message_id,
                                   subject, snippet, from_summary, message_count, unread, in_inbox)
        SELECT m.account_email, m.thread_id,
               MAX(m.internal_date),
               (SELECT id FROM messages m2 WHERE m2.account_email=m.account_email AND m2.thread_id=m.thread_id
                 ORDER BY internal_date DESC, id DESC LIMIT 1),
               (SELECT subject FROM messages m2 WHERE m2.account_email=m.account_email AND m2.thread_id=m.thread_id
                 ORDER BY internal_date DESC, id DESC LIMIT 1),
               (SELECT snippet FROM messages m2 WHERE m2.account_email=m.account_email AND m2.thread_id=m.thread_id
                 ORDER BY internal_date DESC, id DESC LIMIT 1),
               '', COUNT(*),
               MAX(EXISTS(SELECT 1 FROM message_labels ml WHERE ml.account_email=m.account_email AND ml.message_id=m.id AND ml.label_id='UNREAD')),
               MAX(EXISTS(SELECT 1 FROM message_labels ml WHERE ml.account_email=m.account_email AND ml.message_id=m.id AND ml.label_id='INBOX'))
        FROM messages m GROUP BY m.account_email, m.thread_id
        """)

    try db.execute(sql: """
        INSERT INTO message_seq (account_email, message_id) SELECT account_email, id FROM messages
        """)
    try db.execute(sql: """
        INSERT INTO fts_messages (rowid, subject, from_addr, to_addr, body, message_id, thread_id)
        SELECT s.seq, m.subject, m.from_line, m.to_line, IFNULL(b.plain_text,''), m.id, m.thread_id
        FROM messages m JOIN message_seq s ON s.account_email=m.account_email AND s.message_id=m.id
        LEFT JOIN message_bodies b ON b.account_email=m.account_email AND b.message_id=m.id
        """)
}

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

    migrator.registerMigration("v3") { db in
        // --- Query layer schema (M4): denormalized thread rollup + FTS5 index
        // that make the inbox list and search instant, plus split/attachment/
        // AI-artifact tables the query layer builds on. ---

        try db.create(table: "thread_rollup") { t in
            t.column("account_email", .text).notNull()
            t.column("thread_id", .text).notNull()
            t.column("last_message_at", .integer)               // ms since epoch
            t.column("last_message_id", .text)
            t.column("subject", .text).notNull().defaults(to: "")
            t.column("snippet", .text).notNull().defaults(to: "")
            t.column("from_summary", .text).notNull().defaults(to: "")
            t.column("message_count", .integer).notNull().defaults(to: 0)
            t.column("unread", .boolean).notNull().defaults(to: false)
            t.column("in_inbox", .boolean).notNull().defaults(to: false)
            t.column("split_key", .text).notNull().defaults(to: "primary")
            t.column("category", .text).notNull().defaults(to: "")
            t.primaryKey(["account_email", "thread_id"])
        }
        try db.create(
            index: "index_thread_rollup_on_account_email_in_inbox_last_message_at",
            on: "thread_rollup", columns: ["account_email", "in_inbox", "last_message_at"])
        try db.create(
            index: "index_thread_rollup_on_account_email_split_key_last_message_at",
            on: "thread_rollup", columns: ["account_email", "split_key", "last_message_at"])

        try db.create(table: "split_rules") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("account_email", .text).notNull()
            t.column("ordinal", .integer).notNull()
            t.column("predicate_kind", .text).notNull()        // 'sender'|'domain'|'listid'|'category'
            t.column("predicate_value", .text).notNull()
            t.column("split_name", .text).notNull()
        }

        try db.create(table: "attachments") { t in
            t.column("account_email", .text).notNull()
            t.column("message_id", .text).notNull()
            t.column("attachment_id", .text).notNull()
            t.column("filename", .text).notNull().defaults(to: "")
            t.column("mime_type", .text).notNull().defaults(to: "")
            t.column("size", .integer).notNull().defaults(to: 0)
            t.primaryKey(["account_email", "message_id", "attachment_id"])
            t.foreignKey(["account_email", "message_id"],
                         references: "messages", columns: ["account_email", "id"],
                         onDelete: .cascade)
        }

        try db.alter(table: "messages") { t in
            t.add(column: "has_attachment", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "ai_artifacts") { t in
            t.column("account_email", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("artifact_key", .text).notNull()
            t.column("model", .text).notNull()
            t.column("prompt_version", .integer).notNull()
            t.column("content", .text).notNull()
            t.column("created_at", .integer).notNull()          // ms since epoch
            t.primaryKey(["account_email", "kind", "artifact_key", "model", "prompt_version"])
        }
        try db.create(table: "ai_artifact_sources") { t in
            // Provenance for purge: which messages fed a given artifact.
            // Simplified — stores the composite artifact key parts rather than
            // a foreign key to ai_artifacts' rowid, so a source row survives
            // (and can be swept) independently of artifact regeneration.
            t.column("account_email", .text).notNull()
            t.column("artifact_rowid", .integer).notNull()
            t.column("message_id", .text).notNull()
        }
        try db.create(table: "ai_config") { t in
            t.column("account_email", .text).notNull()
            t.column("feature", .text).notNull()
            t.column("model", .text).notNull()
            t.column("base_url", .text)
            t.column("opt_in", .boolean).notNull().defaults(to: false)
            t.primaryKey(["account_email", "feature"])
        }

        // Maps the composite TEXT (account_email, message_id) primary key
        // used everywhere else to a dense integer rowid, because FTS5's
        // implicit rowid must be an integer.
        try db.create(table: "message_seq") { t in
            t.column("account_email", .text).notNull()
            t.column("message_id", .text).notNull()
            t.autoIncrementedPrimaryKey("seq")
        }
        try db.create(
            index: "index_message_seq_on_account_email_message_id",
            on: "message_seq", columns: ["account_email", "message_id"], unique: true)

        // FTS5 is a virtual table — GRDB has no typed builder for it, so this
        // is raw SQL. rowid is message_seq.seq (see bulk build below); the
        // other two columns are UNINDEXED (kept for joins/highlighting, not
        // searched). unicode61 + remove_diacritics normalizes accents; the
        // prefix indexes speed up the "quarter*" typeahead-style queries the
        // inbox search box issues.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE fts_messages USING fts5(
                subject, from_addr, to_addr, body,
                message_id UNINDEXED, thread_id UNINDEXED,
                tokenize='unicode61 remove_diacritics 2',
                prefix='2 3 4'
            )
            """)

        try db.create(
            index: "index_messages_on_account_email_thread_id_internal_date",
            on: "messages", columns: ["account_email", "thread_id", "internal_date"])
        try db.create(
            index: "index_message_labels_on_account_email_label_id_message_id",
            on: "message_labels", columns: ["account_email", "label_id", "message_id"])

        // SQLite can't ALTER TABLE ADD a CHECK constraint onto an existing
        // table without a full rebuild (create-new/copy/drop/rename). A
        // trigger that RAISEs on a bad insert gets the same guarantee — bad
        // op/state values are rejected — without touching the existing
        // mutation_queue rows or its indexes. Folds the M3-deferred LabelOp
        // coercion concern.
        try db.execute(sql: """
            CREATE TRIGGER mutation_queue_op_check
            BEFORE INSERT ON mutation_queue
            WHEN NEW.op NOT IN ('add', 'remove') OR NEW.state NOT IN ('pending', 'in_flight')
            BEGIN
                SELECT RAISE(ABORT, 'mutation_queue: invalid op/state');
            END
            """)

        // --- One-time bulk build: an install with 100k already-synced
        // messages must not open to an empty inbox. This GROUP BY runs
        // exactly once, here, in the migration — the query layer's
        // incremental maintenance (Tasks 2/3) keeps it current afterward.
        // See `runQueryLayerBulkBuild` — shared with QueryLayerMigrationTests
        // so the test exercises the exact SQL the migration runs. ---
        try runQueryLayerBulkBuild(db)
    }

    return migrator
}()
