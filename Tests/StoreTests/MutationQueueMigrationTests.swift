import Foundation
import GRDB
import Testing
@testable import Store

@Test func v2CreatesMutationQueue() throws {
    let database = try HudsonDatabase.inMemory()
    let columns = try database.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(mutation_queue)").map { $0["name"] as String }
    }
    for expected in ["id", "account_email", "message_id", "label_id", "op", "state",
                     "enqueued_at", "expected_history_id"] {
        #expect(columns.contains(expected), "missing column \(expected)")
    }
}

@Test func mutationQueueRejectsDuplicateLiveDelta() throws {
    let database = try HudsonDatabase.inMemory()
    try database.writer.write { db in
        try db.execute(sql: """
            INSERT INTO mutation_queue (account_email, message_id, label_id, op, enqueued_at)
            VALUES ('a', 'm1', 'INBOX', 'remove', 1)
            """)
    }
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO mutation_queue (account_email, message_id, label_id, op, enqueued_at)
                VALUES ('a', 'm1', 'INBOX', 'add', 2)
                """)
        }
    }
}

@Test func mutationQueueRejectsInvalidOpOrStateOnUpdate() throws {
    // The v3 CHECK (`mutation_queue_op_check`) is a BEFORE-INSERT trigger
    // only — it never guarded an UPDATE that corrupts op/state (e.g. a
    // future bug in a flusher's transition SQL), unlike a real column-level
    // CHECK constraint, which enforces on every write. M5 Task 7
    // carry-forward: a BEFORE-UPDATE twin closes that gap.
    let database = try HudsonDatabase.inMemory()
    try database.writer.write { db in
        try db.execute(sql: """
            INSERT INTO mutation_queue (account_email, message_id, label_id, op, state, enqueued_at)
            VALUES ('a', 'm1', 'INBOX', 'remove', 'pending', 1)
            """)
    }
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE mutation_queue SET state = 'bogus'
                WHERE account_email = 'a' AND message_id = 'm1' AND label_id = 'INBOX'
                """)
        }
    }
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE mutation_queue SET op = 'bogus'
                WHERE account_email = 'a' AND message_id = 'm1' AND label_id = 'INBOX'
                """)
        }
    }
    // A legitimate transition (exactly what `markInFlight` does) must still
    // be allowed — the trigger only rejects INVALID values, not updates in
    // general.
    try database.writer.write { db in
        try db.execute(sql: """
            UPDATE mutation_queue SET state = 'in_flight'
            WHERE account_email = 'a' AND message_id = 'm1' AND label_id = 'INBOX'
            """)
    }
    let state = try database.writer.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM mutation_queue WHERE message_id = 'm1'")
    }
    #expect(state == "in_flight")
}

@Test func diskStoreEnablesWALAndNormalSync() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hudson-wal-\(UInt64(bitPattern: Int64(ObjectIdentifier(HudsonDatabase.self).hashValue)))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try HudsonDatabase.open(at: directory.appendingPathComponent("db.sqlite"))
    let (journal, sync) = try database.writer.read { db in
        (try String.fetchOne(db, sql: "PRAGMA journal_mode")!,
         try Int.fetchOne(db, sql: "PRAGMA synchronous")!)
    }
    #expect(journal.lowercased() == "wal")
    #expect(sync == 1)  // NORMAL
}
