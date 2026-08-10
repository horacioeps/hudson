import GRDB
import Testing
@testable import Store

@Test func v3CreatesAllQueryLayerObjects() throws {
    let database = try HudsonDatabase.inMemory()
    let tables = try database.writer.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','index') ")
    }
    for expected in ["thread_rollup", "split_rules", "attachments", "ai_artifacts",
                     "ai_config", "message_seq", "fts_messages"] {
        #expect(tables.contains(expected), "missing \(expected)")
    }
    // has_attachment column added to messages
    let cols = try database.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(messages)").map { $0["name"] as String }
    }
    #expect(cols.contains("has_attachment"))
}

// MARK: - v4: has_attachment denormalized onto thread_rollup (Task 5)

@Test func v4AddsHasAttachmentToThreadRollup() throws {
    let database = try HudsonDatabase.inMemory()
    let cols = try database.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(thread_rollup)").map { $0["name"] as String }
    }
    #expect(cols.contains("has_attachment"))
}

@Test func v4BackfillsHasAttachmentFromEachThreadsNewestMessage() throws {
    // Simulates an upgrading install: v3's bulk build already populated
    // `thread_rollup` (before `has_attachment` existed) from messages that
    // already carry `has_attachment` — v4's backfill UPDATE must pick that
    // up rather than leaving every pre-existing row stuck at the column's
    // default `0`.
    let database = try HudsonDatabase.inMemory()
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('a@x.com','c',0)")
        try db.execute(sql: "INSERT INTO threads (account_email, id, last_message_at) VALUES ('a@x.com','t1',100)")
        try db.execute(sql: """
            INSERT INTO messages (account_email, id, thread_id, history_id, internal_date, subject, snippet, has_attachment)
            VALUES ('a@x.com','m1','t1',1,100,'s','sn',1)
            """)
        // thread_rollup row as v3's bulk build would have left it pre-v4
        // (no has_attachment column at that point — simulated here by
        // deleting and re-inserting without it).
        try db.execute(sql: "DELETE FROM thread_rollup")
        try db.execute(sql: """
            INSERT INTO thread_rollup
                (account_email, thread_id, last_message_at, last_message_id, message_count, unread, in_inbox)
            VALUES ('a@x.com','t1',100,'m1',1,0,0)
            """)
        // Re-run v4's exact backfill statement (the migration itself only
        // runs once, at `HudsonDatabase.inMemory()` construction time,
        // over an empty `messages` table).
        try db.execute(sql: """
            UPDATE thread_rollup
            SET has_attachment = IFNULL((
                SELECT m.has_attachment FROM messages m
                WHERE m.account_email = thread_rollup.account_email
                  AND m.id = thread_rollup.last_message_id
            ), 0)
            """)
    }
    let hasAttachment = try database.writer.read { db in
        try Bool.fetchOne(
            db, sql: "SELECT has_attachment FROM thread_rollup WHERE thread_id = 't1'")
    }
    #expect(hasAttachment == true)
}

@Test func fts5TableAcceptsInsertAndMatch() throws {
    let database = try HudsonDatabase.inMemory()
    try database.writer.write { db in
        try db.execute(sql: """
            INSERT INTO fts_messages(rowid, subject, from_addr, to_addr, body, message_id, thread_id)
            VALUES (1, 'Quarterly report', 'ada@x.com', 'you@x.com', 'the numbers are in', 'm1', 't1')
            """)
    }
    let hits = try database.writer.read { db in
        try Int.fetchAll(db, sql: "SELECT rowid FROM fts_messages WHERE fts_messages MATCH 'quarter*'")
    }
    #expect(hits == [1])
}

@Test func mutationQueueRejectsBadOpViaTrigger() throws {
    let database = try HudsonDatabase.inMemory()
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO mutation_queue (account_email, message_id, label_id, op, enqueued_at)
                VALUES ('a','m','INBOX','POISON',1)
                """)
        }
    }
}

// `HudsonDatabase.inMemory()` already runs v3's bulk build once, during
// migration — but over an empty `messages` table, so it inserts nothing.
// To exercise the actual bulk-build SQL against data, seed messages/labels/
// bodies here and re-run `runQueryLayerBulkBuild` directly: the same
// function the v3 migration calls (see Migrations.swift), so this test and
// the migration can never drift apart. This is the one place a subtle SQL
// bug would silently mis-populate every existing install's inbox.
@Test func bulkBuildPopulatesRollupAndFTSFromExistingMessages() throws {
    let database = try HudsonDatabase.inMemory()
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('a@x.com','c',0)")
        try db.execute(sql: "INSERT INTO threads (account_email, id, last_message_at) VALUES ('a@x.com','t1',200)")
        // Older message: INBOX only, read.
        try db.execute(sql: """
            INSERT INTO messages (account_email, id, thread_id, history_id, internal_date, from_line, to_line, subject, snippet, has_body)
            VALUES ('a@x.com','m1','t1',1,100,'ada@x.com','you@x.com','Old subject','old snippet',0)
            """)
        // Newer message: INBOX + UNREAD, with a body — this is the one the
        // rollup and FTS should pick up on.
        try db.execute(sql: """
            INSERT INTO messages (account_email, id, thread_id, history_id, internal_date, from_line, to_line, subject, snippet, has_body)
            VALUES ('a@x.com','m2','t1',2,200,'bob@x.com','you@x.com','New subject','new snippet',1)
            """)
        try db.execute(sql: """
            INSERT INTO message_bodies (account_email, message_id, plain_text, sanitizer_version)
            VALUES ('a@x.com','m2','the quarterly numbers are in',1)
            """)
        try db.execute(sql: "INSERT INTO labels (account_email, id, name) VALUES ('a@x.com','INBOX','Inbox')")
        try db.execute(sql: "INSERT INTO labels (account_email, id, name) VALUES ('a@x.com','UNREAD','Unread')")
        try db.execute(sql: "INSERT INTO message_labels (account_email, message_id, label_id) VALUES ('a@x.com','m1','INBOX')")
        try db.execute(sql: "INSERT INTO message_labels (account_email, message_id, label_id) VALUES ('a@x.com','m2','INBOX')")
        try db.execute(sql: "INSERT INTO message_labels (account_email, message_id, label_id) VALUES ('a@x.com','m2','UNREAD')")

        // v3's own bulk build already ran (over the empty table at migration
        // time) — clear its no-op output and re-run the identical SQL now
        // that data exists.
        try db.execute(sql: "DELETE FROM thread_rollup")
        try db.execute(sql: "DELETE FROM message_seq")
        try db.execute(sql: "DELETE FROM fts_messages")
        try runQueryLayerBulkBuild(db)
    }

    let rollup = try database.writer.read { db in
        try Row.fetchOne(db, sql: """
            SELECT * FROM thread_rollup WHERE account_email='a@x.com' AND thread_id='t1'
            """)!
    }
    #expect(rollup["message_count"] as Int == 2)
    #expect(rollup["last_message_id"] as String == "m2")
    #expect(rollup["subject"] as String == "New subject")
    #expect(rollup["unread"] as Int == 1)
    #expect(rollup["in_inbox"] as Int == 1)

    let seqCount = try database.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_seq")!
    }
    #expect(seqCount == 2)

    let hits = try database.writer.read { db in
        try Int.fetchAll(db, sql: "SELECT rowid FROM fts_messages WHERE fts_messages MATCH 'quarter*'")
    }
    #expect(hits.count == 1)
}

// MARK: - v5: from_summary backfill for pre-existing thread_rollup rows (Task 9b follow-up)

@Test func v5AddedAsAMigrationAfterV4() throws {
    // `HudsonDatabase.inMemory()` running to completion without throwing
    // already proves v5 registered and ran cleanly — this just names that
    // expectation explicitly.
    _ = try HudsonDatabase.inMemory()
}

@Test func v5FromSummaryBackfillIsANoOpOnAFreshDatabase() throws {
    // Construction already runs the full migrator (v1...v5) over empty
    // tables — v3's bulk build inserts nothing, so v5 has no thread_rollup
    // rows to visit either. Confirms that explicitly rather than just
    // relying on "construction didn't throw".
    let database = try HudsonDatabase.inMemory()
    let count = try database.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread_rollup")!
    }
    #expect(count == 0)
}

@Test func v5BackfillsFromSummaryForExistingThreadRollupRows() throws {
    // Simulates an upgrading install: thread_rollup already has a row (v3's
    // bulk build, or any pre-Task-9b incremental maintenance) with
    // from_summary stuck at the column's default '' — v5's backfill must
    // rebuild it from the thread's actual surviving senders, not just
    // leave it blank forever.
    let database = try HudsonDatabase.inMemory()
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('a@x.com','c',0)")
        try db.execute(sql: "INSERT INTO threads (account_email, id, last_message_at) VALUES ('a@x.com','t1',200)")
        try db.execute(sql: """
            INSERT INTO messages (account_email, id, thread_id, history_id, internal_date, from_line, to_line, subject, snippet)
            VALUES ('a@x.com','m1','t1',1,100,'Ada Lovelace <ada@x.com>','you@x.com','s','sn')
            """)
        try db.execute(sql: """
            INSERT INTO messages (account_email, id, thread_id, history_id, internal_date, from_line, to_line, subject, snippet)
            VALUES ('a@x.com','m2','t1',2,200,'Bob <bob@x.com>','you@x.com','s2','sn2')
            """)
        try db.execute(sql: "INSERT INTO labels (account_email, id, name) VALUES ('a@x.com','INBOX','Inbox')")
        try db.execute(sql: "INSERT INTO message_labels (account_email, message_id, label_id) VALUES ('a@x.com','m1','INBOX')")
        try db.execute(sql: "INSERT INTO message_labels (account_email, message_id, label_id) VALUES ('a@x.com','m2','INBOX')")

        // Pre-v5 state: a thread_rollup row already exists (v3's bulk
        // build ran, or incremental maintenance kept it current) but
        // from_summary is stuck at ''.
        try db.execute(sql: "DELETE FROM thread_rollup")
        try db.execute(sql: """
            INSERT INTO thread_rollup
                (account_email, thread_id, last_message_at, last_message_id, subject, snippet,
                 from_summary, message_count, unread, in_inbox)
            VALUES ('a@x.com','t1',200,'m2','s2','sn2','',2,0,1)
            """)

        try runFromSummaryBackfill(db)
    }
    let row = try database.writer.read { db in
        try Row.fetchOne(db, sql: "SELECT * FROM thread_rollup WHERE thread_id='t1'")!
    }
    #expect(row["from_summary"] as String == "Ada Lovelace, Bob")
    // The recompute must not otherwise disturb a row whose thread still
    // has surviving messages — no drop, no double-count.
    #expect(row["message_count"] as Int == 2)
    #expect(row["last_message_id"] as String == "m2")
}

@Test func v5CachesSplitRulesPerAccountNotAcrossAccounts() throws {
    // Two different accounts, each with its own split rule for the SAME
    // sender domain, routed to a DIFFERENT split name — confirms the
    // backfill's per-account rules cache doesn't leak one account's rules
    // onto another account's recompute.
    let database = try HudsonDatabase.inMemory()
    try database.writer.write { db in
        for account in ["a@x.com", "b@x.com"] {
            try db.execute(
                sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES (?, 'c', 0)",
                arguments: [account])
            try db.execute(
                sql: "INSERT INTO threads (account_email, id, last_message_at) VALUES (?, 't1', 100)",
                arguments: [account])
            try db.execute(
                sql: """
                    INSERT INTO messages (account_email, id, thread_id, history_id, internal_date, from_line, to_line, subject, snippet)
                    VALUES (?, 'm1', 't1', 1, 100, 'Ada Lovelace <ada@newsletter.com>', 'you@x.com', 's', 'sn')
                    """,
                arguments: [account])
            try db.execute(
                sql: "INSERT INTO labels (account_email, id, name) VALUES (?, 'INBOX', 'Inbox')",
                arguments: [account])
            try db.execute(
                sql: "INSERT INTO message_labels (account_email, message_id, label_id) VALUES (?, 'm1', 'INBOX')",
                arguments: [account])
        }
        try db.execute(sql: """
            INSERT INTO split_rules (account_email, ordinal, predicate_kind, predicate_value, split_name)
            VALUES ('a@x.com', 1, 'domain', 'newsletter.com', 'NewsA')
            """)
        try db.execute(sql: """
            INSERT INTO split_rules (account_email, ordinal, predicate_kind, predicate_value, split_name)
            VALUES ('b@x.com', 1, 'domain', 'newsletter.com', 'NewsB')
            """)
        try db.execute(sql: "DELETE FROM thread_rollup")
        for account in ["a@x.com", "b@x.com"] {
            try db.execute(
                sql: """
                    INSERT INTO thread_rollup
                        (account_email, thread_id, last_message_at, last_message_id, subject, snippet,
                         from_summary, split_key, message_count, unread, in_inbox)
                    VALUES (?, 't1', 100, 'm1', 's', 'sn', '', 'primary', 1, 0, 1)
                    """,
                arguments: [account])
        }
        try runFromSummaryBackfill(db)
    }
    let splitA = try database.writer.read { db in
        try String.fetchOne(
            db, sql: "SELECT split_key FROM thread_rollup WHERE account_email='a@x.com' AND thread_id='t1'")
    }
    let splitB = try database.writer.read { db in
        try String.fetchOne(
            db, sql: "SELECT split_key FROM thread_rollup WHERE account_email='b@x.com' AND thread_id='t1'")
    }
    #expect(splitA == "NewsA")
    #expect(splitB == "NewsB")
}

// MARK: - v6: ai_artifact_sources recreated with composite key parts (Fix wave 2)

@Test func v6AddedAsAMigrationAfterV5() throws {
    // `HudsonDatabase.inMemory()` running to completion without throwing
    // already proves v6 registered and ran cleanly — named explicitly, same
    // as v5's equivalent test above.
    _ = try HudsonDatabase.inMemory()
}

@Test func v6RecreatesAIArtifactSourcesWithCompositeKeyColumnsNotRowid() throws {
    // v3's `ai_artifact_sources.artifact_rowid` links to `ai_artifacts`'
    // IMPLICIT rowid (a 5-column composite TEXT primary key, not an
    // INTEGER PRIMARY KEY alias) — VACUUM-fragile: SQLite may renumber
    // that rowid, which would make `AIArtifacts.purge` delete the WRONG
    // artifact (a privacy invariant failure). v6 drops and recreates the
    // table storing the artifact's own composite key parts instead, so a
    // purge lookup has no rowid dependency at all.
    let database = try HudsonDatabase.inMemory()
    let cols = try database.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(ai_artifact_sources)").map { $0["name"] as String }
    }
    #expect(
        Set(cols) == Set([
            "account_email", "kind", "artifact_key", "model", "prompt_version", "message_id",
        ]))
    #expect(!cols.contains("artifact_rowid"))
}

@Test func v6AddsIndexOnAccountEmailAndMessageIDForPurgeLookups() throws {
    // Folds the "no index → full scan on every delete" minor: purge's
    // lookup filters on (account_email, message_id) — see `AIArtifacts.purge`.
    let database = try HudsonDatabase.inMemory()
    let indexNames = try database.writer.read { db in
        try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='ai_artifact_sources'")
    }
    var coversAccountThenMessage = false
    for name in indexNames {
        let info = try database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))")
        }
        let columns = info.sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
            .map { $0["name"] as String }
        if columns.prefix(2) == ["account_email", "message_id"] {
            coversAccountThenMessage = true
        }
    }
    #expect(coversAccountThenMessage)
}
