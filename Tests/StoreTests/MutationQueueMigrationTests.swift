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
