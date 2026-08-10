import GRDB
import Testing
@testable import Store

@Test func schemaV1CreatesAllTables() throws {
    let database = try HudsonDatabase.inMemory()
    let tables = try database.writer.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    }
    for expected in ["accounts", "labels", "message_bodies", "message_labels",
                     "messages", "threads", "tombstones"] {
        #expect(tables.contains(expected), "missing table \(expected)")
    }
}

@Test func foreignKeysAreEnforced() throws {
    let database = try HudsonDatabase.inMemory()
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            // message_labels row for a nonexistent message must be rejected.
            try db.execute(sql: """
                INSERT INTO message_labels (account_email, message_id, label_id)
                VALUES ('a@b.c', 'ghost', 'INBOX')
                """)
        }
    }
}
