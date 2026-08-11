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

/// The one-time backfill run by migration `v5`: rebuilds every EXISTING
/// `thread_rollup` row via the real `ThreadRollup.recomputeThreadRollup`
/// (Task 9b's follow-up). `runQueryLayerBulkBuild` above writes
/// `from_summary` as a literal `''` (it predates sender display names
/// existing at all), and nothing thereafter ever revisits a thread that
/// gets no further activity — so an M2/M3 install migrating through v3
/// gets a full inbox with every sender blank, which can persist forever
/// for a static thread. Exactly the situation `v4`
/// (`v4BackfillsHasAttachmentFromEachThreadsNewestMessage`) already fixed
/// for `has_attachment`, but done here via the authoritative Swift
/// recompute instead of a SQL approximation — so it also self-corrects
/// `split_key`/`category`/`message_count`/`unread`/`in_inbox`/the
/// newest-message fields for any existing row the raw-SQL bulk build (or
/// an older, pre-fix `maintainRollup`) got subtly wrong, not just
/// `from_summary`.
///
/// `SELECT DISTINCT account_email, thread_id FROM thread_rollup` only
/// visits rows that already exist — on a fresh install `thread_rollup` is
/// empty (v3's bulk build ran over an empty `messages` table), so this is
/// a no-op there, same shape as v4's backfill. `recomputeThreadRollup`
/// only ever drops a rollup row when its thread has NO surviving messages
/// — impossible here for consistent data, since a `thread_rollup` row
/// only ever exists alongside at least one `messages` row for that
/// thread; nothing in this backfill touches `messages`, so every row
/// visited here keeps its message(s) and is rebuilt in place, never
/// dropped.
///
/// Split rules are loaded ONCE per account (not once per thread) via a
/// small cache — mirrors `applySnapshots`/`applyHistoryChanges`'s
/// per-batch rules loading in `StoreWrites.swift`. This is a one-time
/// migration cost (O(total messages) across the whole install, run once,
/// ever), not a per-message runtime path, so it isn't asymptotically
/// load-bearing the way `maintainRollup`'s O(1) is — but there's no
/// reason to re-query an account's rules once per thread when an account
/// typically has many. Extracted to a named function (matching
/// `runQueryLayerBulkBuild`'s rationale above) so `QueryLayerMigrationTests`
/// exercises the exact code the migration runs.
func runFromSummaryBackfill(_ db: Database) throws {
    let threads = try Row.fetchAll(
        db, sql: "SELECT DISTINCT account_email, thread_id FROM thread_rollup")
    guard !threads.isEmpty else { return }

    var rulesByAccount: [String: [SplitRule]] = [:]
    for row in threads {
        let account: String = row["account_email"]
        let threadID: String = row["thread_id"]
        let rules: [SplitRule]
        if let cached = rulesByAccount[account] {
            rules = cached
        } else {
            rules = try SplitInbox.fetchRules(account: account, db: db)
            rulesByAccount[account] = rules
        }
        try ThreadRollup.recomputeThreadRollup(
            threadID: threadID, account: account, db: db, rules: rules)
    }
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
            //
            // CORRECTION (M4 final review, fix wave 2 — this comment was
            // edited; the migration's SQL below is untouched, since
            // migrations are append-only): this comment originally claimed
            // the table "stores the composite artifact key parts", but the
            // column below is actually `artifact_rowid` — `ai_artifacts`'
            // IMPLICIT rowid (that table has a 5-column composite TEXT
            // primary key, not an INTEGER PRIMARY KEY alias, so SQLite is
            // free to renumber its rowid on VACUUM). A renumbered rowid
            // would make `AIArtifacts.purge` delete the WRONG artifact —
            // cached AI content of a deleted message surviving is a
            // privacy invariant failure. Migration `v6` below drops and
            // recreates this table storing the composite key parts for
            // real, making the original claim true from then on; this
            // table as created HERE keeps its original (buggy)
            // `artifact_rowid` shape until `v6` runs.
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

    migrator.registerMigration("v4") { db in
        // Task 5: `inboxThreads` reads `thread_rollup` ONLY (zero join, zero
        // aggregation) — so `has_attachment` has to live there too, not be
        // joined from `messages` at read time. It mirrors `subject`/
        // `snippet`'s existing semantics: the flag of the thread's CURRENT
        // newest message, maintained incrementally by
        // `ThreadRollup.maintainRollup`/`recomputeThreadRollup`/
        // `maintainHasAttachment` from here on (see `ThreadRollup.swift`).
        try db.alter(table: "thread_rollup") { t in
            t.add(column: "has_attachment", .boolean).notNull().defaults(to: false)
        }
        // Backfill for installs that already populated `thread_rollup`
        // before this column existed (v3's bulk build, or any incremental
        // maintenance since) — pull the CURRENT newest message's own flag.
        // A brand-new install has no rows here yet (v3's bulk build ran
        // over an empty `messages` table), so this is a no-op there.
        try db.execute(sql: """
            UPDATE thread_rollup
            SET has_attachment = IFNULL((
                SELECT m.has_attachment FROM messages m
                WHERE m.account_email = thread_rollup.account_email
                  AND m.id = thread_rollup.last_message_id
            ), 0)
            """)
    }

    migrator.registerMigration("v5") { db in
        // Task 9b follow-up: backfills `thread_rollup.from_summary` (and
        // self-corrects every other rollup column alongside it) for
        // installs that already have `thread_rollup` rows predating sender
        // display names — the identical situation v4 just fixed for
        // `has_attachment`. See `runFromSummaryBackfill`'s doc comment for
        // the full rationale (no-op on a fresh install, why nothing is
        // wrongly dropped, why this is safe as a one-time migration cost).
        try runFromSummaryBackfill(db)
    }

    migrator.registerMigration("v6") { db in
        // M4 final review, fix wave 2: `ai_artifact_sources` (v3) links to
        // `ai_artifacts`' IMPLICIT rowid via `artifact_rowid INTEGER` —
        // VACUUM-fragile (see the corrected comment on v3's table above)
        // and a contradiction of the plan's actual intent (Task 1's brief:
        // "store the composite artifact key parts"). Drops and recreates
        // the table storing those composite key parts —
        // (account_email, kind, artifact_key, model, prompt_version,
        // message_id) — matching `ai_artifacts`' own primary key exactly,
        // so a purge lookup has no rowid dependency at all, by
        // construction.
        //
        // Safe to DROP + CREATE rather than migrate data: M7 (the feature
        // that will ever populate this table) hasn't shipped, so no
        // installed database has ever written a row here — this is a
        // schema correction over zero rows, not a data migration.
        // `ai_artifacts` itself is untouched; only the sources linkage was
        // wrong.
        try db.drop(table: "ai_artifact_sources")
        try db.create(table: "ai_artifact_sources") { t in
            t.column("account_email", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("artifact_key", .text).notNull()
            t.column("model", .text).notNull()
            t.column("prompt_version", .integer).notNull()
            t.column("message_id", .text).notNull()
        }
        // Folds the "no index → full scan on every delete" minor:
        // `AIArtifacts.purge`'s lookup filters on exactly these two
        // columns.
        try db.create(
            index: "index_ai_artifact_sources_on_account_email_message_id",
            on: "ai_artifact_sources", columns: ["account_email", "message_id"])
    }

    migrator.registerMigration("v7") { db in
        // M5 Task 1: `send_jobs` — the send-side durable queue, mirroring
        // `mutation_queue`'s durability pattern (v2 above). Spec §7.3's
        // dedup protocol needs a send job to survive a crash between "the
        // network call may have reached Gmail" and "we recorded that it
        // did" exactly the way a triage mutation needs to survive one
        // between "sent" and "retired" — same shape, new domain.
        //
        // The state CHECK is declared directly on the column (unlike
        // `mutation_queue_op_check`'s BEFORE-INSERT trigger twin) because
        // this is a fresh CREATE TABLE, not an ALTER onto an existing one —
        // SQLite only refuses to add a CHECK to a table that already exists
        // without a full rebuild; a brand-new table can declare it inline.
        try db.create(table: "send_jobs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("account_email", .text).notNull()
            // UUID Message-ID, assigned by SendService at ENQUEUE time
            // (§7.3) — this is what the restart dedup probe searches Gmail
            // for (`rfc822msgid:<id>`), so it must exist before the first
            // network call, not be derived from Gmail's response.
            t.column("rfc822_message_id", .text).notNull()
            // nil deliberately starts a new thread — the edited-subject
            // case (§7.1): threading requires the FULL triple, so a reply
            // whose subject changed omits threadId on the send call too.
            t.column("thread_id", .text)
            t.column("raw_mime", .blob).notNull()
            t.column("state", .text).notNull().defaults(to: "pending")
                .check(sql: "state IN ('pending', 'held', 'in_flight', 'sent', 'failed')")
            t.column("hold_until", .integer).notNull()   // ms since epoch; undo-send window end
            t.column("enqueued_at", .integer).notNull()  // ms since epoch
            t.column("sent_message_id", .text)           // Gmail's own message id, set by markSent
        }
        // The database-layer half of the dedup guard: the same Message-ID
        // can never be enqueued twice for one account, regardless of
        // caller discipline (SendService's own UUID-per-compose is the
        // other half — this is belt-and-suspenders, not the only guard).
        try db.create(
            index: "send_jobs_unique_rfc822_message_id",
            on: "send_jobs", columns: ["account_email", "rfc822_message_id"], unique: true)
        // Serves both `claimSendable` (state IN pending/held, hold_until
        // filter) and `inFlightSendJobs` (state = in_flight) — both filter
        // on (account, state) first.
        try db.create(
            index: "send_jobs_claim",
            on: "send_jobs", columns: ["account_email", "state", "hold_until"])
    }

    migrator.registerMigration("v8") { db in
        // M5 Task 5: reply threading needs the FULL threading triple
        // (§7.1) — Gmail's own thread id was already on `messages.
        // thread_id` (v1), but the other two legs (`In-Reply-To`/
        // `References`) require the ORIGINAL message's own RFC
        // `Message-ID`/`References` headers, which nothing before this
        // task persisted (v1's `messages` row only kept From/To/Subject/
        // snippet). Two nullable columns, ALTERed onto the existing table
        // — unlike `send_jobs`' v7, which could declare its CHECK inline
        // on a brand-new CREATE TABLE, these are plain nullable adds with
        // no CHECK, so SQLite's ALTER ADD COLUMN applies with no
        // full-table rebuild.
        //
        // `references_header` is stored exactly as Gmail sent it — a
        // single whitespace-separated string of `<id>` tokens (RFC 5322
        // §3.6.4) — not re-parsed into a JSON array at write time; see
        // `MessageSnapshot.referencesHeader`'s doc comment for why.
        try db.alter(table: "messages") { t in
            t.add(column: "rfc822_message_id", .text)
            t.add(column: "references_header", .text)
        }
    }

    return migrator
}()
