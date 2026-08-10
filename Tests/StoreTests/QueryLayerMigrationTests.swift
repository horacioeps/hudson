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
