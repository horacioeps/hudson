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
