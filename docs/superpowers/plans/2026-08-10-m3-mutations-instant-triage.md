# M3 — Mutations + Incremental Sync (Instant Triage) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Triage (archive / star / read / label) applies instantly and locally — the change is visible in the next read the moment you press a key — while a background flusher pushes it to Gmail invisibly and converges under conflict, never losing a local action.

**Architecture:** Canonical tables (`messages`/`message_labels`) stay **pure server truth**. A new `mutation_queue` holds pending label deltas; reads return **effective state = canonical XOR pending deltas** via a SQL overlay, so a just-archived message drops from the inbox read with zero network wait. A flusher — split from the sync pass, woken by an `AsyncStream` — drains the queue through Gmail `messages.modify`/`batchModify`, retiring each overlay entry by the `historyId` the modify returns (gated on the account cursor catching up), so there is no reappear-flicker. Terminal failures converge via a version-guarded minimal re-fetch, never an inverse-op guess. The heavy backfill is isolated from triage by a QuotaBucket **priority lane** and by batching backfill/history into one transaction per page.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, GRDB.swift 7, swift-argument-parser. No new dependencies.

**Design source of truth:** `docs/superpowers/design/2026-08-10-speed-ai-architecture.md` (§ "M3") and `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` (§4 SyncEngine, §5 mutation queue / rebase-overlay conflict model). Read the M3 section of the architecture doc before implementing — it carries the rationale behind every decision below.

## Global Constraints

_(every task inherits these)_

- Swift 6 language mode, macOS 15+. Dependencies: swift-argument-parser + GRDB.swift only.
- **Dependency rule (spec §2):** `Store` imports neither GmailKit nor networking; `GmailKit` never imports GRDB; only `SyncEngine` composes both; CLI uses public APIs.
- **Canonical stays server truth (spec §5):** triage NEVER destructively writes `message_labels`; it enqueues a delta. Effective state is computed as an overlay at read time. History's `replaceLabels` therefore churns canonical invisibly and needs no overlay re-application.
- **Overlay retirement (architecture M3):** an overlay entry retires when the modify's returned `historyId` has been reached by the account cursor (`account.history_cursor >= H`), NOT on 2xx alone (2xx opens a reappear-flicker window before the echo poll lands).
- **Never `await` inside a GRDB transaction closure** (they are synchronous `db in` bodies); actors use async GRDB APIs.
- **Never-log (spec §9.1):** no tokens/secrets/message content/ids in logs; network logs carry method + path **template** + status only.
- **Quota (spec §4.5, architecture M3):** costs — `messages.modify` = 5, `messages.batchModify` = 50, plus existing (get=20, list=5, history=2, send=100). Reserve ~1,000 u/min of the ~5,500 bucket for the **interactive** class so foreground triage never queues behind the ~6h backfill.
- **Readable/reviewed bar** (memory `hudson-code-standards`): doc comments on every public type/method (initializers included), descriptive names, files ~200 lines, no dead code, pristine test output. This is an open-source repo people will scrutinize.
- TDD: failing test first (RED evidence), then implement (GREEN), commit per task.

---

### Task 1: Migration v2 — `mutation_queue` table + SQLite PRAGMAs

**Files:**
- Modify: `Sources/Store/Migrations.swift` (append migration `v2`)
- Modify: `Sources/Store/HudsonDatabase.swift` (PRAGMAs via `Configuration.prepareDatabase`)
- Test: `Tests/StoreTests/MutationQueueMigrationTests.swift`

**Interfaces:**
- Consumes: existing `migrator`, `HudsonDatabase.open`/`inMemory`.
- Produces: a `mutation_queue` table and a WAL/tuned database configuration. Schema:
  - `mutation_queue`: `id INTEGER PK AUTOINCREMENT`, `account_email TEXT NOT NULL`, `message_id TEXT NOT NULL`, `label_id TEXT NOT NULL`, `op TEXT NOT NULL` (`'add'|'remove'`), `state TEXT NOT NULL DEFAULT 'pending'` (`'pending'|'in_flight'`), `enqueued_at INTEGER NOT NULL` (ms), `expected_history_id INTEGER` (set to the modify's returned historyId once in_flight, for retirement gating), plus a **partial UNIQUE index** on `(account_email, message_id, label_id)` so the same message+label has at most one live delta (a later opposite op replaces it — handled in Task 2), and an index on `(account_email, state, id)` for FIFO draining.

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/MutationQueueMigrationTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MutationQueueMigrationTests`
Expected: FAIL — `mutation_queue` does not exist; journal_mode is not WAL.

- [ ] **Step 3: Implement**

Append to `Migrations.swift` after the `v1` block:

```swift
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
```

In `HudsonDatabase.swift`, add a shared configuration builder and use it in BOTH `open` and `inMemory`:

```swift
    /// Tuned configuration (spec §4.6 + architecture M3). WAL + synchronous=NORMAL
    /// is safe because Gmail is the source of truth — a lost last commit on power
    /// failure re-syncs. cache_size/mmap_size/busy_timeout keep triage enqueues
    /// off the fsync path. WAL only applies to on-disk pools; the in-memory test
    /// queue silently keeps its default journal.
    static func tunedConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -20000")   // ~20 MB
            try db.execute(sql: "PRAGMA mmap_size = 268435456")  // 256 MB
        }
        return configuration
    }
```

Replace the two ad-hoc `Configuration()` constructions with `Self.tunedConfiguration()`. (Note: `PRAGMA journal_mode = WAL` is a no-op returning `memory` on an in-memory `DatabaseQueue` — harmless; the WAL assertion test uses an on-disk store.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MutationQueueMigrationTests`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(store): migration v2 mutation_queue + WAL/NORMAL PRAGMAs"
```

---

### Task 2: Enqueue mutations + effective-label overlay reads

**Files:**
- Create: `Sources/Store/MutationQueue.swift`
- Modify: `Sources/Store/StoreReads.swift` (effective labels in `messageRow`)
- Test: `Tests/StoreTests/OverlayReadTests.swift`

**Interfaces:**
- Consumes: `HudsonDatabase`, `applySnapshot` (Task-4/M2), `MessageRow`.
- Produces (on `HudsonDatabase`):
  - `public enum LabelOp: String, Sendable { case add, remove }`
  - `public struct PendingMutation: Sendable, Equatable { public let id: Int64; public let messageID: String; public let labelID: String; public let op: LabelOp; public let state: String; public let expectedHistoryID: Int64? }`
  - `func enqueueMutation(messageID: String, labelID: String, op: LabelOp, account: String, now: Int64) async throws` — one transaction: if an opposite live delta exists for the same (message,label), it is a **cancel** (delete the row, net no-op); if a same-op live delta exists, no-op; else insert. This keeps the queue minimal and idempotent.
  - **Change** `StoreReads.messageRow` so `labelIDs` reflects the overlay: effective = (canonical labels ∪ pending adds) − pending removes, evaluated in SQL. `recentMessages` must also apply the overlay to its inbox filter later (Task 11 uses it); for M3, `messageRow` returning effective labels is the core.

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/OverlayReadTests.swift`:

```swift
import Testing
@testable import Store

private func seed(_ db: HudsonDatabase, id: String, labels: [String]) async throws {
    let snap = MessageSnapshot(
        id: id, threadID: "t", historyID: 1, internalDate: 1000,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: labels)
    _ = try await db.applySnapshot(snap, account: "x")
}

@Test func pendingRemoveHidesLabelFromReads() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seed(db, id: "m1", labels: ["INBOX", "UNREAD"])
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(!row.labelIDs.contains("INBOX"))   // effective view: archived
    #expect(row.labelIDs.contains("UNREAD"))
    // Canonical is untouched — server truth preserved.
    let canonical = try await db.writer.read { try String.fetchAll($0,
        sql: "SELECT label_id FROM message_labels WHERE account_email='x' AND message_id='m1' ORDER BY label_id") }
    #expect(canonical == ["INBOX", "UNREAD"])
}

@Test func pendingAddShowsLabelInReads() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seed(db, id: "m1", labels: ["INBOX"])
    try await db.enqueueMutation(messageID: "m1", labelID: "STARRED", op: .add, account: "x", now: 1)
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(row.labelIDs.contains("STARRED"))
}

@Test func oppositeOpCancelsPendingDelta() async throws {
    let db = try HudsonDatabase.inMemory()
    try await seed(db, id: "m1", labels: ["INBOX"])
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .add, account: "x", now: 2)
    // Re-adding what you just archived cancels out — no live delta, no flush needed.
    #expect(try await db.pendingMutations(account: "x").isEmpty)
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(row.labelIDs.contains("INBOX"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OverlayReadTests`
Expected: FAIL — `enqueueMutation`/`pendingMutations` not defined; reads ignore the overlay.

- [ ] **Step 3: Implement**

`Sources/Store/MutationQueue.swift`:

```swift
import Foundation
import GRDB

/// Which way a pending label delta points.
public enum LabelOp: String, Sendable, Equatable { case add, remove }

/// One live, not-yet-confirmed local label change.
public struct PendingMutation: Sendable, Equatable {
    public let id: Int64
    public let messageID: String
    public let labelID: String
    public let op: LabelOp
    public let state: String
    public let expectedHistoryID: Int64?
}

extension HudsonDatabase {
    /// Enqueues a label delta as PENDING SERVER TRUTH-PRESERVING intent
    /// (spec §5): canonical tables are never written here. Opposite op to a
    /// live delta cancels it (net no-op); same op is idempotent.
    public func enqueueMutation(
        messageID: String, labelID: String, op: LabelOp, account: String, now: Int64
    ) async throws {
        try await writer.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, op FROM mutation_queue
                    WHERE account_email = ? AND message_id = ? AND label_id = ?
                    """,
                arguments: [account, messageID, labelID])
            if let existing {
                let existingOp: String = existing["op"]
                if existingOp == op.rawValue { return }            // same op: idempotent
                let id: Int64 = existing["id"]
                try db.execute(
                    sql: "DELETE FROM mutation_queue WHERE id = ?", arguments: [id])  // opposite: cancel
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO mutation_queue
                        (account_email, message_id, label_id, op, enqueued_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [account, messageID, labelID, op.rawValue, now])
        }
    }

    /// All live deltas for an account, oldest first (drain order).
    public func pendingMutations(account: String) async throws -> [PendingMutation] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM mutation_queue WHERE account_email = ? ORDER BY id",
                arguments: [account]
            ).map(Self.pendingMutation(from:))
        }
    }

    static func pendingMutation(from row: Row) -> PendingMutation {
        PendingMutation(
            id: row["id"], messageID: row["message_id"], labelID: row["label_id"],
            op: LabelOp(rawValue: row["op"]) ?? .add, state: row["state"],
            expectedHistoryID: row["expected_history_id"])
    }
}
```

In `StoreReads.swift`, replace the label fetch inside `messageRow` with an overlay-aware query:

```swift
    static func messageRow(from raw: Row, account: String, db: Database) throws -> MessageRow {
        let id: String = raw["id"]
        // Effective labels = (canonical ∪ pending adds) − pending removes.
        let labels = try String.fetchAll(
            db,
            sql: """
                SELECT label_id FROM (
                    SELECT label_id FROM message_labels
                    WHERE account_email = :acct AND message_id = :mid
                    UNION
                    SELECT label_id FROM mutation_queue
                    WHERE account_email = :acct AND message_id = :mid AND op = 'add'
                ) AS present
                WHERE label_id NOT IN (
                    SELECT label_id FROM mutation_queue
                    WHERE account_email = :acct AND message_id = :mid AND op = 'remove'
                )
                ORDER BY label_id
                """,
            arguments: ["acct": account, "mid": id])
        return MessageRow(
            id: id, threadID: raw["thread_id"], historyID: raw["history_id"],
            internalDate: raw["internal_date"], fromLine: raw["from_line"],
            toLine: raw["to_line"], subject: raw["subject"], snippet: raw["snippet"],
            hasBody: raw["has_body"], labelIDs: labels)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OverlayReadTests`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(store): enqueue mutations + effective-label overlay reads (server truth preserved)"
```

---

### Task 3: Retire, mark-in-flight, and drop mutations

**Files:**
- Modify: `Sources/Store/MutationQueue.swift`
- Test: `Tests/StoreTests/MutationRetirementTests.swift`

**Interfaces:**
- Produces (on `HudsonDatabase`):
  - `func markInFlight(mutationIDs: [Int64], expectedHistoryID: Int64, account: String) async throws` — sets `state='in_flight'`, records the modify's returned historyId as the retirement gate.
  - `func retireConfirmedMutations(account: String) async throws -> Int` — deletes every `in_flight` row whose `expected_history_id <= account.history_cursor` (the echo poll has landed), returns the count retired. This is the anti-flicker gate.
  - `func dropMutation(id: Int64, account: String) async throws` — terminal-failure removal (the flusher then re-fetches truth, Task 9).
  - `func claimPendingBatch(account: String, limit: Int) async throws -> [PendingMutation]` — returns up to `limit` oldest `pending` rows (FIFO) for the flusher to send.

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/MutationRetirementTests.swift`:

```swift
import Testing
@testable import Store

private func account(_ db: HudsonDatabase, cursor: Int64?) async throws {
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    if let cursor {
        try await db.writer.write { try $0.execute(
            sql: "UPDATE accounts SET history_cursor = ? WHERE email = 'x'", arguments: [cursor]) }
    }
}

@Test func retiresOnlyWhenCursorReachesExpectedHistory() async throws {
    let db = try HudsonDatabase.inMemory()
    try await account(db, cursor: 100)
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let pending = try await db.claimPendingBatch(account: "x", limit: 10)
    try await db.markInFlight(mutationIDs: pending.map(\.id), expectedHistoryID: 150, account: "x")

    // Cursor still behind 150 → nothing retires (the echo hasn't landed; retiring now would flicker).
    #expect(try await db.retireConfirmedMutations(account: "x") == 0)
    #expect(try await db.pendingMutations(account: "x").count == 1)

    // Cursor catches up → retire.
    try await db.writer.write { try $0.execute(
        sql: "UPDATE accounts SET history_cursor = 150 WHERE email = 'x'") }
    #expect(try await db.retireConfirmedMutations(account: "x") == 1)
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}

@Test func dropRemovesWithoutGate() async throws {
    let db = try HudsonDatabase.inMemory()
    try await account(db, cursor: 100)
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let id = try await db.pendingMutations(account: "x").first!.id
    try await db.dropMutation(id: id, account: "x")
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MutationRetirementTests`
Expected: FAIL — methods not defined.

- [ ] **Step 3: Implement** (append to `MutationQueue.swift`)

```swift
extension HudsonDatabase {
    /// Oldest `pending` rows for the flusher to send, FIFO.
    public func claimPendingBatch(account: String, limit: Int) async throws -> [PendingMutation] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM mutation_queue
                    WHERE account_email = ? AND state = 'pending' ORDER BY id LIMIT ?
                    """,
                arguments: [account, limit]
            ).map(Self.pendingMutation(from:))
        }
    }

    /// Marks sent mutations in_flight and records the historyId the modify
    /// returned as the retirement gate (spec §5 / architecture M3).
    public func markInFlight(
        mutationIDs: [Int64], expectedHistoryID: Int64, account: String
    ) async throws {
        guard !mutationIDs.isEmpty else { return }
        try await writer.write { db in
            let placeholders = databaseQuestionMarks(count: mutationIDs.count)
            try db.execute(
                sql: """
                    UPDATE mutation_queue SET state = 'in_flight', expected_history_id = ?
                    WHERE account_email = ? AND id IN (\(placeholders))
                    """,
                arguments: StatementArguments([expectedHistoryID, account] + mutationIDs))
        }
    }

    /// Retires in_flight deltas whose echo has landed (account cursor has
    /// reached the modify's historyId). Retiring earlier — on 2xx — would drop
    /// the overlay before the canonical write echoes back, flickering the row.
    public func retireConfirmedMutations(account: String) async throws -> Int {
        try await writer.write { db in
            let cursor = try Int64.fetchOne(
                db, sql: "SELECT history_cursor FROM accounts WHERE email = ?",
                arguments: [account])
            guard let cursor else { return 0 }
            try db.execute(
                sql: """
                    DELETE FROM mutation_queue
                    WHERE account_email = ? AND state = 'in_flight'
                      AND expected_history_id IS NOT NULL AND expected_history_id <= ?
                    """,
                arguments: [account, cursor])
            return db.changesCount
        }
    }

    /// Terminal-failure removal — the flusher re-derives truth afterwards.
    public func dropMutation(id: Int64, account: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM mutation_queue WHERE id = ? AND account_email = ?",
                arguments: [id, account])
        }
    }
}

/// `?, ?, …` of length `count` for an IN clause.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MutationRetirementTests`
Expected: 2 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(store): mutation retirement gated on history cursor, drop, and claim-batch"
```

---

### Task 4: GmailClient `post` core (handles 204 + request body)

**Files:**
- Modify: `Sources/GmailKit/API/GmailClient.swift`
- Test: `Tests/GmailKitTests/PostCoreTests.swift`

**Interfaces:**
- Consumes: existing request core (`get`), `MockTransport`, `GmailError`, `QuotaBucket`.
- Produces (internal to GmailKit, mirroring `get`):
  - `func post<Body: Encodable, Response: Decodable>(template: String, path: String, body: Body, cost: Int) async throws -> Response`
  - `func postVoid<Body: Encodable>(template: String, path: String, body: Body, cost: Int) async throws` — succeeds on 200 **and 204** (batchModify returns 204 with an empty body; the `get` core would throw trying to JSON-decode it). Same quota/token/retry policy as `get`.
- The retry/token/quota logic is identical to `get`; factor the shared attempt loop so `get`/`post`/`postVoid` don't duplicate it. Extract a private `perform(method:template:path:query:body:cost:) -> (Data, HTTPURLResponse)` that does quota + token + retry and returns the final successful (data,response) or throws; `get` decodes JSON from it, `post` decodes, `postVoid` ignores the body. **Success is status 200 or 204** in `perform`; callers that require a body handle an unexpected 204 themselves.

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/PostCoreTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

private func makeClient(_ transport: MockTransport) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture), account: "a")
    let session = AccountSession(
        account: "a",
        oauth: OAuthClient(credentials: OAuthCredentials(clientID: "i", clientSecret: "s"), transport: transport),
        store: store)
    return GmailClient(session: session, transport: transport, quota: QuotaBucket())
}

private struct Empty: Encodable {}

@Test func postVoidSucceedsOn204EmptyBody() async throws {
    let transport = MockTransport(responses: [(Data(), 204)])
    try await makeClient(transport).postVoid(
        template: "users/me/messages/batchModify", path: "users/me/messages/batchModify",
        body: Empty(), cost: GmailQuotaCost.messagesBatchModify)
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

@Test func postDecodes200Body() async throws {
    let body = #"{"id":"m1","threadId":"t","historyId":"42"}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let message: GmailMessage = try await makeClient(transport).post(
        template: "users/me/messages/{id}/modify", path: "users/me/messages/m1/modify",
        body: Empty(), cost: GmailQuotaCost.messagesModify)
    #expect(message.historyId == "42")
}

@Test func postStillRetriesServerErrorsThenSucceeds() async throws {
    let ok = #"{"id":"m1","threadId":"t","historyId":"42"}"#
    let transport = MockTransport(responses: [(Data(), 503), (Data(ok.utf8), 200)])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport)  // uses real sleep; inject via a client sleep param if needed
    // NOTE: reuse the existing GmailClientTests LockedBox pattern; if GmailClient's
    // post path shares the get sleep injection, assert one backoff sleep occurred.
    let message: GmailMessage = try await client.post(
        template: "t", path: "users/me/messages/m1/modify", body: Empty(),
        cost: GmailQuotaCost.messagesModify)
    #expect(message.historyId == "42")
    _ = sleeps
}
```

(If the shared `perform` needs the injected `sleep` to assert backoff deterministically, thread the existing `sleep` closure through it exactly as `get` already does.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PostCoreTests`
Expected: FAIL — `post`/`postVoid`/`messagesModify`/`messagesBatchModify` undefined.

- [ ] **Step 3: Implement**

Add to `GmailQuotaCost` (in `QuotaBucket.swift`):

```swift
    public static let messagesModify = 5
    public static let messagesBatchModify = 50
```

Refactor `GmailClient`: extract the attempt loop into `perform(method:template:path:query:body:cost:)` returning `(Data, HTTPURLResponse)` on a 200/204 and throwing otherwise. `get` becomes `perform(method: "GET", …)` + JSON decode. Add:

```swift
    /// POST returning a decoded body (e.g. messages.modify → Message).
    func post<Body: Encodable, Response: Decodable>(
        template: String, path: String, body: Body, cost: Int
    ) async throws -> Response {
        let (data, _) = try await perform(
            method: "POST", template: template, path: path, body: body, cost: cost)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// POST with no meaningful response body — succeeds on 200 or 204
    /// (batchModify returns 204). The `get` core would throw decoding the
    /// empty 204 body; this path must not.
    func postVoid<Body: Encodable>(
        template: String, path: String, body: Body, cost: Int
    ) async throws {
        _ = try await perform(method: "POST", template: template, path: path, body: body, cost: cost)
    }
```

`perform` sets the JSON body when present (`request.httpBody = try JSONEncoder().encode(body)`, `Content-Type: application/json`), sets the method, and treats `200, 204` as success. Keep the log line `"\(method) \(template) -> \(status)"` (template only, §9.1). GET callers pass `body: nil` — make `perform` generic-over-optional-body or provide a `performNoBody` for GET; pick whichever keeps the diff cleanest, but **do not duplicate the retry loop**.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all pass (existing GmailClient tests unchanged + 3 new).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): post/postVoid transport core (204-safe) sharing the retry loop"
```

---

### Task 5: `modify` + `batchModify` endpoints

**Files:**
- Create: `Sources/GmailKit/API/ModifyEndpoints.swift`
- Modify: `Sources/SyncEngine/SyncEngine.swift` (extend `GmailAPI` protocol + conformance is automatic on `GmailClient`)
- Test: `Tests/GmailKitTests/ModifyEndpointTests.swift`

**Interfaces:**
- Produces on `GmailClient`:
  - `func modify(id: String, addLabelIDs: [String], removeLabelIDs: [String]) async throws -> GmailMessage` — POST `users/me/messages/{id}/modify`, template `users/me/messages/{id}/modify`, cost `messagesModify`. Returns the full Message (carries `historyId` for retirement gating).
  - `func batchModify(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws` — POST `users/me/messages/batchModify`, 204, cost `messagesBatchModify`.
- Add both to the `GmailAPI` protocol in `SyncEngine.swift` so the flusher (Task 9) and `ScriptedGmail` can use them.
- Request body encodes `{ "addLabelIds": [...], "removeLabelIds": [...] }` (and `"ids": [...]` for batch), omitting empty arrays via a small Encodable that only includes non-empty fields (Gmail rejects some empty combinations; simplest: always include both arrays — Gmail accepts empty arrays).

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/ModifyEndpointTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

private func makeClient(_ transport: MockTransport) throws -> GmailClient { /* same helper as PostCoreTests */ 
    let store = InMemoryTokenStore()
    try store.saveTokens(TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture), account: "a")
    let session = AccountSession(account: "a",
        oauth: OAuthClient(credentials: OAuthCredentials(clientID: "i", clientSecret: "s"), transport: transport),
        store: store)
    return GmailClient(session: session, transport: transport, quota: QuotaBucket())
}

@Test func modifyPostsLabelsAndReturnsMessage() async throws {
    let body = #"{"id":"m1","threadId":"t","historyId":"77","labelIds":["UNREAD"]}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let message = try await makeClient(transport).modify(
        id: "m1", addLabelIDs: [], removeLabelIDs: ["INBOX"])
    #expect(message.historyId == "77")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages/m1/modify")
    let sent = try #require(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: sent) as! [String: Any]
    #expect(json["removeLabelIds"] as? [String] == ["INBOX"])
}

@Test func batchModifyPostsIdsAnd204s() async throws {
    let transport = MockTransport(responses: [(Data(), 204)])
    try await makeClient(transport).batchModify(
        ids: ["m1", "m2"], addLabelIDs: ["STARRED"], removeLabelIDs: [])
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages/batchModify")
    let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect((json["ids"] as? [String])?.sorted() == ["m1", "m2"])
    #expect(json["addLabelIds"] as? [String] == ["STARRED"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModifyEndpointTests`
Expected: FAIL — `modify`/`batchModify` undefined.

- [ ] **Step 3: Implement**

`Sources/GmailKit/API/ModifyEndpoints.swift`:

```swift
import Foundation

/// Request body for messages.modify.
private struct ModifyBody: Encodable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

/// Request body for messages.batchModify.
private struct BatchModifyBody: Encodable {
    let ids: [String]
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

extension GmailClient {
    /// Applies label changes to one message and returns the updated Message —
    /// its `historyId` is the retirement gate for the optimistic overlay.
    public func modify(
        id: String, addLabelIDs: [String], removeLabelIDs: [String]
    ) async throws -> GmailMessage {
        try await post(
            template: "users/me/messages/{id}/modify",
            path: "users/me/messages/\(id)/modify",
            body: ModifyBody(addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs),
            cost: GmailQuotaCost.messagesModify)
    }

    /// Applies the SAME label change to up to 1000 messages (204, no body).
    /// Cheaper per-message than N modifies; used to coalesce rapid triage.
    public func batchModify(
        ids: [String], addLabelIDs: [String], removeLabelIDs: [String]
    ) async throws {
        try await postVoid(
            template: "users/me/messages/batchModify",
            path: "users/me/messages/batchModify",
            body: BatchModifyBody(ids: ids, addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs),
            cost: GmailQuotaCost.messagesBatchModify)
    }
}
```

In `SyncEngine.swift`, extend `GmailAPI`:

```swift
    func modify(id: String, addLabelIDs: [String], removeLabelIDs: [String]) async throws -> GmailMessage
    func batchModify(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws
```

(`extension GmailClient: GmailAPI {}` picks these up automatically.)

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all pass. (`ScriptedGmail` in SyncEngineTests must add stubs for the two new protocol methods — add them returning a canned Message / recording the call, so the SyncEngine tests still compile.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): messages.modify + batchModify endpoints"
```

---

### Task 6: QuotaBucket priority lane + per-waiter cancellation

_(Folds in the M2-deferred full per-waiter cancellation.)_

**Files:**
- Modify: `Sources/GmailKit/Transport/QuotaBucket.swift`
- Test: `Tests/GmailKitTests/QuotaBucketPriorityTests.swift`

**Interfaces:**
- Produces:
  - `public enum QuotaClass: Sendable { case interactive, background }`
  - `func acquire(cost: Int, class quotaClass: QuotaClass) async throws` — the existing `acquire(cost:)` becomes `acquire(cost:, class: .background)` (default keeps all M2 callers as background). Interactive acquirers are served ahead of background ones AND draw from a reserved sub-budget so a saturated background lane (the 6h backfill) can't starve a foreground modify.
  - **Cancellation:** a waiter whose task is cancelled while queued is removed and throws `CancellationError` promptly (via `withTaskCancellationHandler`), instead of sitting until its grant. This replaces the M2 fail-safe-only behavior.
- Discipline: reserve `interactiveReserve` (default 1,000) u/min. Background admission is capped at `unitsPerMinute - interactiveReserve` of in-window spend; interactive admission uses the full `unitsPerMinute`. Within a class, FIFO. Interactive waiters drain before background waiters.

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/QuotaBucketPriorityTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

// Reuse VirtualClock / LockedOrder patterns from the existing QuotaBucket tests.

@Test func interactiveIsServedAheadOfQueuedBackground() async throws {
    let clock = VirtualClock()
    // Small window so background must wait; interactive reserve lets foreground through.
    let bucket = QuotaBucket(unitsPerMinute: 100, interactiveReserve: 40,
                             now: { clock.now }, sleep: { clock.sleep($0) })
    try await bucket.acquire(cost: 80, class: .background)  // window at 80/100
    let order = LockedOrder()
    async let bg: Void = { try await bucket.acquire(cost: 30, class: .background); order.append("bg") }()
    try await Task.sleep(for: .milliseconds(50))
    async let fg: Void = { try await bucket.acquire(cost: 15, class: .interactive); order.append("fg") }()
    _ = try await (bg, fg)
    // Interactive fits within reserve immediately (80+15<=100); background (80+30>100) waits for the window.
    #expect(order.values.first == "fg")
}

@Test func cancelledWaiterThrowsPromptly() async throws {
    let clock = VirtualClock()
    let bucket = QuotaBucket(unitsPerMinute: 100, now: { clock.now }, sleep: { clock.sleep($0) })
    try await bucket.acquire(cost: 100, class: .background)  // saturate
    let task = Task { try await bucket.acquire(cost: 50, class: .background) }
    try await Task.sleep(for: .milliseconds(50))  // let it enqueue
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func existingAcquireDefaultsToBackground() async throws {
    let bucket = QuotaBucket(unitsPerMinute: 100)
    try await bucket.acquire(cost: 10)  // M2 signature still compiles, behaves as background
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QuotaBucketPriorityTests`
Expected: FAIL — `interactiveReserve`/`QuotaClass`/`acquire(cost:class:)` undefined; cancellation not honored.

- [ ] **Step 3: Implement**

Rework `QuotaBucket`: add `interactiveReserve` to `init` (default 1,000); `enum QuotaClass`; store waiters as `(cost, class, id, continuation)` with a monotonic `nextWaiterID`. `acquire(cost:)` delegates to `acquire(cost:, class: .background)`. Admission check:
- interactive fits iff `spentInWindow() + cost <= unitsPerMinute`
- background fits iff `spentInWindow() + cost <= unitsPerMinute - interactiveReserve`

Drain order: all interactive waiters (FIFO by id) before any background waiter. Wrap the per-waiter suspension in `withTaskCancellationHandler` so a cancelled waiter is removed from `waiters` (by id) and resumed with `CancellationError`; guard resume-once (a waiter already granted/removed is not double-resumed). Keep the single-drain-task invariant. This is the meatier concurrency task — mirror the existing resolve-once discipline from the M1 LoopbackServer state machine (one funnel that resumes a waiter's continuation exactly once, transitions it out of the queue).

**Reviewer note for the dispatch:** this task carries real concurrency risk (double-resume, stranded waiter, drain/cancel race). Its review should trace resume-once on every path: granted, cancelled-while-queued, cancelled-after-grant, drain-empty vs enqueue.

- [ ] **Step 4: Run the full suite**

Run: `swift test` (run `--filter QuotaBucket` several times — flake check on the timing-based priority test).
Expected: all pass, no flakes.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): QuotaBucket interactive/background priority lane + per-waiter cancellation"
```

---

### Task 7: Batched per-page snapshot writes with per-message SAVEPOINT

**Files:**
- Modify: `Sources/Store/StoreWrites.swift` (add batch API)
- Modify: `Sources/SyncEngine/SyncEngine.swift` (backfill uses the batch)
- Test: `Tests/StoreTests/BatchApplyTests.swift`

**Interfaces:**
- Produces on `HudsonDatabase`:
  - `func applySnapshots(_ snapshots: [MessageSnapshot], account: String) async throws -> Int` — applies a whole page in ONE transaction; each message wrapped in a `SAVEPOINT` so one bad row rolls back only itself, not the page. Returns the count that applied (`.applied` outcomes). This is the primary lever against the ValueObservation storm (one commit per page instead of per message — ~100x fewer commits).
- `SyncEngine.backfill` collects the page's snapshots and calls `applySnapshots` once per page instead of `applySnapshot` per message. (Per-message get still happens per message; only the WRITES batch.)

- [ ] **Step 1: Write the failing test**

`Tests/StoreTests/BatchApplyTests.swift`:

```swift
import GRDB
import Testing
@testable import Store

@Test func batchAppliesAllInOneTransactionAndCountsApplied() async throws {
    let db = try HudsonDatabase.inMemory()
    let snaps = (1...3).map { i in
        MessageSnapshot(id: "m\(i)", threadID: "t", historyID: Int64(i), internalDate: Int64(i),
            fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]) }
    let applied = try await db.applySnapshots(snaps, account: "x")
    #expect(applied == 3)
    #expect(try await db.recentMessages(account: "x", limit: 10).count == 3)
}

@Test func oneStaleMessageInBatchDoesNotBlockOthers() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(MessageSnapshot(id: "m2", threadID: "t", historyID: 99,
        internalDate: 2, fromLine: "f", toLine: "t", subject: "s2", snippet: "sn", labelIDs: ["INBOX"]),
        account: "x")
    // Batch includes a STALE m2 (older historyID) plus fresh m1, m3.
    let snaps = [
        MessageSnapshot(id: "m1", threadID: "t", historyID: 1, internalDate: 1, fromLine: "f", toLine: "t", subject: "s1", snippet: "sn", labelIDs: ["INBOX"]),
        MessageSnapshot(id: "m2", threadID: "t", historyID: 5, internalDate: 2, fromLine: "f", toLine: "t", subject: "OLD", snippet: "sn", labelIDs: ["INBOX"]),
        MessageSnapshot(id: "m3", threadID: "t", historyID: 3, internalDate: 3, fromLine: "f", toLine: "t", subject: "s3", snippet: "sn", labelIDs: ["INBOX"]),
    ]
    let applied = try await db.applySnapshots(snaps, account: "x")
    #expect(applied == 2)  // m1, m3 applied; m2 stale
    let m2 = try #require(try await db.message(id: "m2", account: "x")).row
    #expect(m2.subject == "s2")  // stale write rejected, newer kept
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BatchApplyTests`
Expected: FAIL — `applySnapshots` undefined.

- [ ] **Step 3: Implement**

In `StoreWrites.swift`:

```swift
    /// Applies a page of snapshots in ONE transaction, each guarded by a
    /// SAVEPOINT so a single failing/stale row rolls back only itself. Cutting
    /// commits from per-message to per-page is the load-bearing control against
    /// the SwiftUI ValueObservation storm during the ~6h backfill (architecture M3).
    public func applySnapshots(
        _ snapshots: [MessageSnapshot], account: String
    ) async throws -> Int {
        try await writer.write { db in
            var applied = 0
            for snapshot in snapshots {
                do {
                    try db.execute(sql: "SAVEPOINT s")
                    let outcome = try Self.applySnapshotInTransaction(snapshot, account: account, db: db)
                    try db.execute(sql: "RELEASE s")
                    if outcome == .applied { applied += 1 }
                } catch {
                    try db.execute(sql: "ROLLBACK TO s")
                    try db.execute(sql: "RELEASE s")
                }
            }
            return applied
        }
    }
```

In `SyncEngine.backfill`, replace the per-message `applySnapshot` loop body: still `getMessage` per ref (skipping per-message 404 via `logSkippedMessage`), collect the successful snapshots into an array, then one `applySnapshots(snapshots, account:)` after the ref loop; set `added` from its return.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all pass (existing backfill tests still green — the batched path is behavior-equivalent on counts).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(store,sync): batched per-page snapshot writes with per-message SAVEPOINT"
```

---

### Task 8: Per-page cursor crash-window fix (defer cursor to end of poll)

_(M2-review-deferred obligation.)_

**Files:**
- Modify: `Sources/SyncEngine/SyncEngine.swift` (`pollHistory`)
- Modify: `Sources/Store/StoreWrites.swift` (allow applying changes without advancing the cursor)
- Test: `Tests/SyncEngineTests/PollCursorTests.swift`

**Interfaces:**
- The problem (M2 review): `pollHistory` commits `newCursor = page.historyId` per page, but Gmail returns the *current mailbox* historyId on every page, so page 1 commits the final cursor while pages 2..N are still unapplied — a crash between pages loses them.
- Fix: apply each page's changes **without** advancing the stored cursor, and write the cursor **once, after the last page**. Re-polling from the old cursor after a crash re-applies pages idempotently (the §4.2 version guard makes re-application safe).
- Produces: `applyHistory(_:newCursor:account:)` gains a sibling `applyHistoryChanges(_:account:) -> [String]` that applies changes + returns unknown ids but does NOT touch the cursor; add `advanceCursor(to:account:) async throws` (guarded: only advances forward, `WHERE history_cursor IS NULL OR history_cursor < ?`). `pollHistory` calls `applyHistoryChanges` per page and `advanceCursor(to: finalHistoryId)` after the loop.

- [ ] **Step 1: Write the failing test**

`Tests/SyncEngineTests/PollCursorTests.swift`:

```swift
import GmailKit
import Store
import Testing
@testable import SyncEngine

@Test func cursorAdvancesOnlyAfterAllHistoryPagesApplied() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail()
    let engine = SyncEngine(api: gmail, database: db, account: "x")
    _ = try await engine.syncOnce()  // seeds cursor 100 (default profile), empty backfill

    // Two-page history poll: page 1 has nextPageToken, page 2 finishes; both carry historyId 130.
    await gmail.setHistory([
        historyPage(#"{"historyId":"130","nextPageToken":"p2","history":[{"id":"110","messagesAdded":[{"message":{"id":"m1","threadId":"t","historyId":"110","internalDate":"1","labelIds":["INBOX"],"snippet":"s","payload":{"headers":[{"name":"Subject","value":"a"}]}}}]}]}"#),
        historyPage(#"{"historyId":"130","history":[{"id":"120","messagesAdded":[{"message":{"id":"m2","threadId":"t","historyId":"120","internalDate":"2","labelIds":["INBOX"],"snippet":"s","payload":{"headers":[{"name":"Subject","value":"b"}]}}}]}]}"#),
    ])
    _ = try await engine.syncOnce()
    // Both messages applied AND the cursor advanced exactly once to 130.
    #expect(try await db.recentMessages(account: "x", limit: 10).map(\.id).sorted() == ["m1", "m2"])
    let cursor = try await db.writer.read { try Int64.fetchOne($0, sql: "SELECT history_cursor FROM accounts WHERE email='x'") }
    #expect(cursor == 130)
}
```

(Add `historyPage` helper if not already shared into ScriptedGmail from M2.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PollCursorTests`
Expected: FAIL until `applyHistoryChanges`/`advanceCursor` exist and `pollHistory` defers the cursor.

- [ ] **Step 3: Implement** — refactor `applyHistory` to compose `applyHistoryChanges` + `advanceCursor`; add `advanceCursor` (forward-only guard); rewrite `pollHistory`'s loop to apply changes per page and advance the cursor once after the loop with the last page's `historyId`. Keep the 404 expiry path and hydration-404 skip intact.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all pass (existing history tests still green; `applyHistory` keeps its signature by delegating).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "fix(sync): defer history cursor advance to end of pagination (crash-window)"
```

---

### Task 9: Mutation flusher (split loop, AsyncStream wakeup, converge)

**Files:**
- Create: `Sources/SyncEngine/MutationFlusher.swift`
- Modify: `Sources/SyncEngine/SyncEngine.swift` (expose a `wakeFlusher()` signal; flusher runs its own loop)
- Test: `Tests/SyncEngineTests/FlusherTests.swift`

**Interfaces:**
- Produces:
  - `public actor MutationFlusher` — `init(api: any GmailAPI, database: HudsonDatabase, account: String)`; `func flushOnce() async throws -> FlushReport` (single-flight; drains `claimPendingBatch`, groups by identical (add,remove) label sets → `batchModify` for groups >1, `modify` for singletons; marks in_flight with the returned/derived historyId; retires confirmed; on terminal 4xx drops the mutation and re-fetches truth via `getMessage(format: "minimal")` through the version guard). `struct FlushReport: Sendable, Equatable { var flushed: Int; var retired: Int; var dropped: Int }`.
  - `func start()` / an `AsyncStream` continuation so an enqueue can wake the flush loop in <5ms rather than waiting for a poll tick (the loop `for await _ in signals { try? await flushOnce() }`).
- **historyId for the overlay gate:** `modify` returns a Message with `historyId` → use it directly. `batchModify` returns 204 (no historyId) → after a successful batch, call `getProfile()` and use its `historyId` as the ceiling (architecture M3: "capture a historyId ceiling via getProfile"). Mark those mutations in_flight with that ceiling.
- Uses the **interactive** quota class for modify/batchModify (foreground triage must not queue behind backfill).

- [ ] **Step 1: Write the failing tests**

`Tests/SyncEngineTests/FlusherTests.swift`:

```swift
import GmailKit
import Store
import Testing
@testable import SyncEngine

@Test func flushSendsModifyAndRetiresAfterCursorCatchesUp() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    try await db.writer.write { try $0.execute(sql: "UPDATE accounts SET history_cursor=100 WHERE email='x'") }
    // seed a message + an archive delta
    _ = try await db.applySnapshot(MessageSnapshot(id: "m1", threadID: "t", historyID: 90,
        internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)

    let gmail = ScriptedGmail()
    await gmail.setModifyResult(GmailMessageStub(id: "m1", historyId: "140"))  // modify returns historyId 140
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")

    let r1 = try await flusher.flushOnce()
    #expect(r1.flushed == 1)
    #expect(r1.retired == 0)                      // cursor(100) < 140, overlay stays → no flicker
    #expect(try await db.pendingMutations(account: "x").first?.state == "in_flight")

    try await db.writer.write { try $0.execute(sql: "UPDATE accounts SET history_cursor=140 WHERE email='x'") }
    let r2 = try await flusher.flushOnce()
    #expect(r2.retired == 1)
    #expect(try await db.pendingMutations(account: "x").isEmpty)
}

@Test func terminalFailureDropsAndReconverges() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(MessageSnapshot(id: "m1", threadID: "t", historyID: 90,
        internalDate: 1, fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"]), account: "x")
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove, account: "x", now: 1)
    let gmail = ScriptedGmail()
    await gmail.setModifyError(GmailError.invalidRequest(status: 400, message: "bad label"))
    // The re-fetch after drop returns the true current message.
    await gmail.setMessages(["m1": testMessage(id: "m1", historyID: 200, labels: ["INBOX"])])
    let flusher = MutationFlusher(api: gmail, database: db, account: "x")
    let r = try await flusher.flushOnce()
    #expect(r.dropped == 1)
    #expect(try await db.pendingMutations(account: "x").isEmpty)  // overlay gone, truth re-fetched
    let row = try #require(try await db.message(id: "m1", account: "x")).row
    #expect(row.labelIDs.contains("INBOX"))  // converged to server truth (still in inbox)
}
```

(Extend `ScriptedGmail` with `setModifyResult`/`setModifyError`/`batchModify` recording and a `GmailMessageStub` helper or reuse `testMessage`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FlusherTests`
Expected: FAIL — `MutationFlusher` undefined.

- [ ] **Step 3: Implement** `MutationFlusher` per the interfaces. Single-flight guard like SyncEngine; group claimed mutations by identical (addLabels, removeLabels) key; batch groups of >1, modify singletons; mark in_flight with the historyId (modify's own; batch's via getProfile ceiling); retire confirmed; on terminal 4xx (`invalidRequest`) drop + `getMessage(format: "minimal")` → `applySnapshot`. Rate-limit/5xx errors leave the mutation `pending` for the next flush (don't drop). Wire the AsyncStream wakeup.

**Reviewer note for the dispatch:** trace the flusher's convergence — a mutation must never be lost (dropped-without-reconverge), never double-sent, and the overlay must not retire before the echo (cursor gate). Watch the batch historyId-ceiling: getProfile's historyId is ≥ the batch's effect, so the gate may retire slightly late (safe) but never early (unsafe).

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(sync): mutation flusher — coalesced modify/batchModify, cursor-gated retire, terminal reconverge"
```

---

### Task 10: Two-phase Runtime (read-only commands skip the Keychain)

_(M2-review-deferred obligation.)_

**Files:**
- Modify: `Sources/HudsonCLI/Runtime.swift`
- Modify: `Sources/HudsonCLI/ListCommand.swift`, `ShowCommand.swift`, `SyncCommand.swift` (status path)
- Test: `Tests/HudsonCLITests/RuntimeLocalTests.swift`

**Interfaces:**
- Produces:
  - `struct LocalRuntime { let database: HudsonDatabase; let account: AccountRecord }` + `static func local() async throws -> LocalRuntime` — opens the DB, runs migration, loads the primary account, **never touches the Keychain or builds a network client**. Throws the same `GmailError.auth("No account connected …")` when absent.
  - `Runtime.bootstrap()` stays the full graph (Keychain + client + engine + flusher) for `sync`/triage.
- `list`, `show`, and `sync --status` switch to `LocalRuntime.local()`; `sync` (network) and the triage commands (Task 11) keep `Runtime.bootstrap()`.

- [ ] **Step 1: Write the failing test**

`Tests/HudsonCLITests/RuntimeLocalTests.swift`:

```swift
import Foundation
import GmailKit
import Store
import Testing
@testable import HudsonCLI

@Test func localRuntimeThrowsCleanlyWithNoAccount() async throws {
    // Point at a throwaway empty DB via the injectable path seam (add a
    // `local(databaseURL:)` overload for tests; the no-arg uses HudsonPaths).
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hudson-local-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: GmailError.self) {
        _ = try await LocalRuntime.local(databaseURL: dir.appendingPathComponent("db.sqlite"))
    }
}
```

(Use a `UUID`-free deterministic dir name if the test env forbids `UUID()`; a fixed name under a per-test temp dir is fine.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RuntimeLocalTests`
Expected: FAIL — `LocalRuntime` undefined.

- [ ] **Step 3: Implement** `LocalRuntime` + `local(databaseURL:)` (and a no-arg `local()` using `HudsonPaths.databaseURL`). Rewire the three read-only command paths. Keep `reportAndFail` error rendering.

- [ ] **Step 4: Run the full suite + a local smoke check**

Run: `swift test` (all pass). Then `swift build` and confirm the read-only commands still compile against `LocalRuntime`. (Live Keychain-free run is verified by the operator — the point is `list`/`show`/`--status` no longer prompt.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(cli): two-phase Runtime — read-only commands skip the Keychain"
```

---

### Task 11: Triage CLI — archive/star/read/label/unarchive + pending + undo

**Files:**
- Create: `Sources/HudsonCLI/TriageCommands.swift`
- Create: `Sources/HudsonCLI/PendingCommand.swift`
- Modify: `Sources/HudsonCLI/HudsonCommand.swift` (register)
- Modify: `Sources/HudsonCLI/Runtime.swift` (bootstrap builds the flusher; a `flush` call after enqueue)

**Interfaces:**
- Consumes: `enqueueMutation`, `pendingMutations`, `MutationFlusher`, `LocalRuntime`/`Runtime`.
- Produces commands (all optimistic — enqueue + return instantly; the flush happens in the same process after printing, or via an explicit `--no-flush`):
  - `hudson archive <id>` (remove INBOX), `hudson unarchive <id>` (add INBOX), `hudson star <id>` / `hudson unstar <id>` (add/remove STARRED), `hudson read <id>` / `hudson unread <id>` (remove/add UNREAD), `hudson label <id> --add X --remove Y`.
  - `hudson pending` — lists queued mutations (message id, op, label, state) via `LocalRuntime` (no Keychain).
  - `hudson undo <id>` — enqueues the inverse of the newest live delta for that message (architecture M3: undo is an inverse-delta enqueue, never a direct un-modify — avoids the TOCTOU where the flusher is mid-send).
- The enqueue path uses `LocalRuntime` (instant, no Keychain) to write the mutation; the flush (network) uses `Runtime.bootstrap()` + `MutationFlusher.flushOnce()`. So `hudson archive` shows instant local effect even offline; flushing is best-effort and retried.

- [ ] **Step 1: Implement the commands** (thin, following the ProfileCommand/reportAndFail pattern). Each triage command: `LocalRuntime.local()` → `enqueueMutation(...)` → print the new effective state → then attempt a flush via `Runtime.bootstrap()` unless `--no-flush` (catch flush errors and report "queued, will retry" rather than failing the command — the local effect already succeeded). All message-derived output through `Sanitizer.terminalSafe(_, singleLine: true)` for any row fields (carried obligation from M2 Task 7 — the singleLine variant exists for exactly this).

- [ ] **Step 2: Build + full suite**

Run: `swift build` (zero warnings) + `swift test` (all pass). No new unit tests required for the thin commands beyond what Tasks 2/3/9 cover; add a small test for `undo` computing the correct inverse delta if practical.

- [ ] **Step 3: Live verification (operator)** — record as PENDING OPERATOR (Keychain gate), with the exact sequence to run: `hudson sync` (populate), `hudson list`, `hudson archive <id>`, `hudson list` (message gone instantly), `hudson pending` (shows the queued/in_flight delta), `hudson sync` (flush + retire), `hudson list` (still archived, now confirmed). Note it in the report.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(cli): optimistic triage commands (archive/star/read/label/unarchive), pending, undo"
```

---

### Task 12: Docs — spec §5 refinement, architecture cross-ref, README

**Files:**
- Modify: `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` (§5 mark M3 mechanisms as built; §11 M3 → DONE)
- Modify: `README.md` (quickstart gains triage commands; status line)

- [ ] **Step 1:** Update §11 M3 bullet to `**M3 — DONE**`; add a short note to §5 that the overlay/retirement/flusher are implemented as the architecture doc describes. README Try section gains `hudson archive/star/read/label` and `hudson pending`; status blockquote notes instant local triage.

- [ ] **Step 2:** Verify the documented commands exist via `.build/debug/hudson --help`; commit.

```bash
git add -A && git commit -m "docs: spec/README for M3 instant triage"
```

---

## Self-Review (completed at plan-writing time)

1. **Design coverage:** mutation_queue + PRAGMAs (T1); enqueue + overlay reads (T2); retire/in-flight/drop/claim (T3); post/postVoid 204-safe core (T4); modify/batchModify (T5); priority lane + cancellation (T6, folds M2 obligation); batched SAVEPOINT writes (T7, the ValueObservation-storm lever); per-page cursor crash-window (T8, M2 obligation); flusher with cursor-gated retire + terminal reconverge (T9); two-phase Runtime (T10, M2 obligation); triage CLI + undo + pending (T11); docs (T12). The in-memory `@Published` <16ms overlay is explicitly a UI-phase concern (architecture doc) — M3 delivers the durable queue + read-time SQL overlay + flusher that the UI overlay will sit on; not in scope here.
2. **Placeholder scan:** no TBDs. T4's `perform` refactor and T6's cancellation are described with enough specificity (shared-loop, resolve-once discipline referencing the M1 LoopbackServer pattern) that the implementer+reviewer loop closes them; both carry explicit reviewer-focus notes.
3. **Type consistency:** `LabelOp`, `PendingMutation`, `enqueueMutation`, `pendingMutations`, `claimPendingBatch`, `markInFlight`, `retireConfirmedMutations`, `dropMutation`, `applySnapshots`, `applyHistoryChanges`, `advanceCursor`, `modify`/`batchModify`, `QuotaClass`, `acquire(cost:class:)`, `MutationFlusher`/`FlushReport`, `LocalRuntime.local(databaseURL:)` are used with identical signatures across the tasks that define and consume them. `GmailQuotaCost.messagesModify=5`/`messagesBatchModify=50` defined in T4, used in T5/T9. `ScriptedGmail` gains modify/batchModify stubs in T5 (needed to keep SyncEngine tests compiling) and result/error setters in T9.
