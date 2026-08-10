# M4 — Query Layer (Instant Read Path: Rollup + Search + Split Inbox) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every inbox surface resolves from one index-backed, LIMIT-bounded query with zero N+1 and zero query-time aggregation; search is instant local FTS5; split inbox (incl. Gmail categories) falls out of a precomputed rollup — the read foundation the SwiftUI shell will sit on.

**Architecture:** A materialized `thread_rollup` table becomes the SOLE inbox-list surface, maintained **incrementally** (O(1) per message) as snapshots apply — never a read-time `GROUP BY` over ~50k threads. A plain FTS5 `fts_messages` table gives bm25 full-text search, maintained inside the same write transaction as the row change. `split_rules` + a `split_key` column on the rollup power split inbox; Gmail `CATEGORY_*` labels give category splits for free. Attachments metadata and the AIKit pre-hooks (ai_artifacts/ai_config, LLMKeyStore) land here so M7 grafts cleanly.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, GRDB.swift 7 (FTS5 via SQLite), swift-argument-parser. No new dependencies.

**Design source of truth:** `docs/superpowers/design/2026-08-10-speed-ai-architecture.md` (§ "M4 — Query layer" and the **performance contract**). Read that M4 section before implementing — it carries the rationale and latency budgets. Also spec `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` §3 (Store), §3.4 (split inbox).

## Global Constraints

_(every task inherits these)_

- Swift 6 language mode, macOS 15+. Dependencies: swift-argument-parser + GRDB.swift only.
- **Dependency rule (spec §2):** `Store` imports neither GmailKit nor networking; `GmailKit` never imports GRDB; only `SyncEngine` composes both; CLI uses public APIs.
- **The rollup is the SOLE inbox-list surface** and is maintained **incrementally and O(1) per message, touching only the one affected thread** (architecture M4 — the biggest risk: a naive full recompute per write is O(N²) across newest-first backfill of large threads). Never a read-time `GROUP BY`.
- **Migration bulk-build is mandatory:** the M4 migration MUST one-time-build `thread_rollup` (GROUP BY over already-backfilled messages) AND populate `fts_messages` from existing messages/bodies — else an install with 100k M2/M3 messages gets an empty inbox + empty search until a full resync.
- **FTS maintenance happens inside the same GRDB write transaction as the source-row change** (stub on message insert; delete+reinsert on body arrival / sanitizer-version bump; delete on purge). No external-content table — consistency is the app's responsibility. A 2–3 char query floor (the prefix index is `2 3 4`).
- **Overlay composes with reads:** every inbox/search query must reflect the M3 mutation overlay (a just-archived message drops from `in:inbox`). Canonical stays server truth.
- **No `await` inside a GRDB transaction closure.** Never-log (spec §9.1): no ids/content in logs. Message-derived CLI output through `Sanitizer.terminalSafe(_, singleLine: true)`.
- **Readable/reviewed bar** (memory `hudson-code-standards`): doc comments on every public type/method, descriptive names, files ~200 lines, no dead code, pristine tests. Open-source scrutiny.
- TDD: failing test first (RED evidence), then implement (GREEN), commit per task. Migrations are append-only (v1, v2 exist; add **v3**).

---

### Task 1: Migration v3 — schema (rollup, fts, split_rules, attachments, ai_*, seq/map, indexes, CHECKs)

**Files:**
- Modify: `Sources/Store/Migrations.swift` (append migration `v3`)
- Modify: `Sources/Store/HudsonDatabase.swift` (one-line `busyMode` seconds comment — folds an M3-deferred minor)
- Test: `Tests/StoreTests/QueryLayerMigrationTests.swift`

**Interfaces:**
- Produces (DDL only — maintenance logic is Tasks 2/3; the one-time bulk populate is Step 3 below, raw SQL in the migration):
  - `thread_rollup` (PK `account_email, thread_id`): `last_message_at INTEGER`, `last_message_id TEXT`, `subject TEXT NOT NULL DEFAULT ''`, `snippet TEXT NOT NULL DEFAULT ''`, `from_summary TEXT NOT NULL DEFAULT ''`, `message_count INTEGER NOT NULL DEFAULT 0`, `unread INTEGER NOT NULL DEFAULT 0`, `in_inbox INTEGER NOT NULL DEFAULT 0`, `split_key TEXT NOT NULL DEFAULT 'primary'`, `category TEXT NOT NULL DEFAULT ''`
  - `split_rules` (PK autoinc `id`): `account_email TEXT NOT NULL`, `ordinal INTEGER NOT NULL`, `predicate_kind TEXT NOT NULL` (`sender|domain|listid|category`), `predicate_value TEXT NOT NULL`, `split_name TEXT NOT NULL`
  - `attachments`: `account_email TEXT NOT NULL`, `message_id TEXT NOT NULL`, `attachment_id TEXT NOT NULL`, `filename TEXT NOT NULL DEFAULT ''`, `mime_type TEXT NOT NULL DEFAULT ''`, `size INTEGER NOT NULL DEFAULT 0`, PK `(account_email, message_id, attachment_id)`, FK `(account_email, message_id)→messages(account_email,id) ON DELETE CASCADE`
  - add `has_attachment BOOLEAN NOT NULL DEFAULT 0` to `messages` (via `ALTER TABLE messages ADD COLUMN`)
  - `ai_artifacts`: `account_email TEXT NOT NULL`, `kind TEXT NOT NULL`, `artifact_key TEXT NOT NULL`, `model TEXT NOT NULL`, `prompt_version INTEGER NOT NULL`, `content TEXT NOT NULL`, `created_at INTEGER NOT NULL`, PK `(account_email, kind, artifact_key, model, prompt_version)`
  - `ai_artifact_sources`: `account_email TEXT NOT NULL`, `artifact_rowid INTEGER NOT NULL`, `message_id TEXT NOT NULL` (provenance for purge; simplified: store the composite artifact key parts — see code)
  - `ai_config`: `account_email TEXT NOT NULL`, `feature TEXT NOT NULL`, `model TEXT NOT NULL`, `base_url TEXT`, `opt_in INTEGER NOT NULL DEFAULT 0`, PK `(account_email, feature)`
  - `message_seq` (`account_email TEXT`, `message_id TEXT`, `seq INTEGER PRIMARY KEY AUTOINCREMENT`, UNIQUE `(account_email, message_id)`) — maps composite TEXT PK → integer FTS rowid
  - `fts_messages` — FTS5 virtual table: `subject, from_addr, to_addr, body, message_id UNINDEXED, thread_id UNINDEXED`, `tokenize='unicode61 remove_diacritics 2'`, `prefix='2 3 4'`
  - indexes: `messages(account_email, thread_id, internal_date)`, `message_labels(account_email, label_id, message_id)`, `thread_rollup(account_email, in_inbox, last_message_at)`, `thread_rollup(account_email, split_key, last_message_at)`
  - CHECK constraint on `mutation_queue.op IN ('add','remove')` and `state IN ('pending','in_flight')` — folds the M3-deferred LabelOp coercion concern. (SQLite can't add a CHECK to an existing table without a table rebuild; do it via the 12-step `ALTER`→create-new→copy→drop→rename, OR — simpler and acceptable — add a **trigger** `mutation_queue_op_check` that RAISEs on a bad op/state insert. Use the trigger; document why.)

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/QueryLayerMigrationTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QueryLayerMigrationTests`
Expected: FAIL — objects don't exist.

- [ ] **Step 3: Implement migration v3**

Append `migrator.registerMigration("v3") { db in … }` after `v2`. Create every table/index/FTS vtable/trigger above with GRDB's `db.create(...)` (and raw `db.execute(sql:)` for the FTS5 `CREATE VIRTUAL TABLE fts_messages USING fts5(subject, from_addr, to_addr, body, message_id UNINDEXED, thread_id UNINDEXED, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')` and the check trigger). **One-time bulk build (raw SQL, at the end of the v3 closure):**

```sql
-- thread_rollup from existing messages (GROUP BY runs ONCE, in the migration)
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
FROM messages m GROUP BY m.account_email, m.thread_id;
```

and populate `message_seq` + `fts_messages` from existing rows:

```sql
INSERT INTO message_seq (account_email, message_id) SELECT account_email, id FROM messages;
INSERT INTO fts_messages (rowid, subject, from_addr, to_addr, body, message_id, thread_id)
SELECT s.seq, m.subject, m.from_line, m.to_line, IFNULL(b.plain_text,''), m.id, m.thread_id
FROM messages m JOIN message_seq s ON s.account_email=m.account_email AND s.message_id=m.id
LEFT JOIN message_bodies b ON b.account_email=m.account_email AND b.message_id=m.id;
```

(`from_summary`/`split_key`/`category` are filled by the incremental maintenance going forward and default sensibly; the bulk build leaves `from_summary=''`/`split_key='primary'` — acceptable, Task 7 recomputes split_key on next touch and the UI shows the last sender from the message join until then.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QueryLayerMigrationTests`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(store): migration v3 — thread_rollup, fts5, split_rules, attachments, ai_* + bulk build"
```

---

### Task 2: Incremental thread_rollup maintenance (O(1) per message)

**Files:**
- Create: `Sources/Store/ThreadRollup.swift`
- Modify: `Sources/Store/StoreWrites.swift` (`applySnapshotInTransaction` calls the maintainer)
- Test: `Tests/StoreTests/ThreadRollupTests.swift`

**Interfaces:**
- Consumes: `applySnapshotInTransaction` (StoreWrites), `thread_rollup` (Task 1).
- Produces: `static func maintainRollup(afterApplying snapshot: MessageSnapshot, wasInsert: Bool, account: String, db: Database) throws` — updates exactly the one thread's rollup row:
  - `message_count` += 1 **only on insert** (a re-applied update of an existing message must not double-count)
  - `last_message_at = MAX(existing, snapshot.internalDate)`; when the snapshot is the new newest, also set `last_message_id/subject/snippet`
  - `unread`/`in_inbox` recomputed for the thread from the snapshot's labels combined with the row's prior value — **but** the correct incremental rule is: `unread = 1` if any message in the thread is unread. On a label-only change that *clears* the last unread, an OR-merge can't lower it → a **targeted per-thread recompute** is required for unread-clearing/inbox-removing label events (a bounded `EXISTS`/`COUNT` over the thread's messages, still touching only one thread). `applySnapshotInTransaction` handles snapshots (message content+labels); the `.labels` history path (StoreWrites `applyHistoryChanges`) must call a `recomputeThreadFlags(threadID:account:db:)` for label changes.
  - `applySnapshotInTransaction` must return/expose whether the write was an **insert vs update** (query `EXISTS` before the upsert, or use the tombstone/history check already there + a pre-check) so `maintainRollup` knows whether to increment the count.
- Also: `static func recomputeThreadFlags(threadID:account:db:) throws` — sets `unread`/`in_inbox` for one thread via `MAX(EXISTS(... UNREAD/INBOX ...))` over that thread's messages, applying the M3 overlay so a pending archive is reflected. (Overlay-aware: effective labels, not raw message_labels.)

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/ThreadRollupTests.swift`:

```swift
import GRDB
import Testing
@testable import Store

private func snap(_ id: String, thread: String = "t1", date: Int64, labels: [String], subject: String = "s") -> MessageSnapshot {
    MessageSnapshot(id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: "ada@x.com", toLine: "you@x.com", subject: subject, snippet: "sn", labelIDs: labels)
}

@Test func rollupCountsMessagesOncePerInsert() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: ["INBOX","UNREAD"]), account: "x")
    _ = try await db.applySnapshot(snap("m2", date: 2, labels: ["INBOX"]), account: "x")
    _ = try await db.applySnapshot(snap("m1", date: 3, labels: ["INBOX","UNREAD"]), account: "x")  // update, not new
    let row = try #require(try await db.inboxThreads(account: "x", split: nil, limit: 10).first)
    #expect(row.messageCount == 2)                 // m1 update did not double-count
    #expect(row.lastMessageAt == 3)                // newest wins
    #expect(row.unread == true)                    // m1 unread
}

@Test func clearingLastUnreadLowersThreadUnread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: ["INBOX","UNREAD"]), account: "x")
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).first?.unread == true)
    // A label event removes UNREAD → thread must recompute to unread=false.
    _ = try await db.applyHistory(
        [HistoryChange(kind: .labels(id: "m1", historyID: 5, labelIDs: ["INBOX"]))],
        newCursor: 5, account: "x")
    #expect(try await db.inboxThreads(account: "x", split: nil, limit: 10).first?.unread == false)
}

@Test func rollupMaintenanceStaysBoundedOnLargeThread() async throws {
    let db = try HudsonDatabase.inMemory()
    // 500 messages in ONE thread applied newest-first — must not degrade to O(N^2).
    for i in stride(from: 500, through: 1, by: -1) {
        _ = try await db.applySnapshot(snap("m\(i)", date: Int64(i), labels: ["INBOX"]), account: "x")
    }
    let row = try #require(try await db.inboxThreads(account: "x", split: nil, limit: 10).first)
    #expect(row.messageCount == 500)
    #expect(row.lastMessageAt == 500)
    // (The assertion that matters for the risk is correctness at count; the reviewer/impl
    //  should confirm no per-message full-thread scan — maintainRollup touches one row.)
}
```

- [ ] **Step 2–5:** RED → implement `ThreadRollup.maintainRollup`/`recomputeThreadFlags`, wire into `applySnapshotInTransaction` (pass `wasInsert`) and `applyHistoryChanges`'s `.labels` branch → GREEN → commit `feat(store): incremental O(1) thread_rollup maintenance + targeted unread recompute`.

*(`inboxThreads` is defined in Task 5; for Tasks 2–4 tests, add a minimal internal `inboxThreads` early or assert via raw `thread_rollup` SELECT. To keep tasks independently testable, Task 2's tests may read `thread_rollup` directly rather than depend on Task 5 — adjust the test to `SELECT message_count,last_message_at,unread FROM thread_rollup` if `inboxThreads` isn't in yet. The implementer picks whichever keeps this task self-contained; note it in the report.)*

---

### Task 3: FTS5 index maintenance (seq map, stub/reindex/delete in-transaction)

**Files:**
- Create: `Sources/Store/FTSIndex.swift`
- Modify: `Sources/Store/StoreWrites.swift` (stub on insert), `Sources/Store/StoreBodies.swift` (reindex on body arrival / sanitizer bump), `Sources/Store/StoreWrites.swift` `deleteVanishedMessage` + any purge (delete)
- Test: `Tests/StoreTests/FTSMaintenanceTests.swift`

**Interfaces:**
- Produces:
  - `static func seq(for messageID: String, account: String, db: Database) throws -> Int64` — allocates/looks up the `message_seq` integer rowid.
  - `static func stubIndex(_ snapshot: MessageSnapshot, account: String, db: Database) throws` — INSERT (or the FTS delete+reinsert protocol on update) the subject/from/to/message_id/thread_id with empty body, at the message's seq rowid. Called from `applySnapshotInTransaction`.
  - `static func reindexBody(messageID: String, account: String, plainText: String, db: Database) throws` — FTS delete-then-reinsert for that rowid **with body** (the FTS5 delete+reinsert protocol for a plain table). Called from `saveBody`.
  - `static func deleteIndex(messageID: String, account: String, db: Database) throws` — remove the FTS row + the seq map row. Called from `deleteVanishedMessage`.
  - All operate inside the caller's existing write transaction (synchronous `db`).
- integrity-check test: after randomized insert/reindex/delete, `INSERT INTO fts_messages(fts_messages) VALUES('integrity-check')` must not throw, and a MATCH count equals the expected surviving rows.

- [ ] **Steps:** RED (a test that a message's subject is searchable after apply, body searchable after saveBody, gone after delete, and integrity-check passes) → implement → GREEN → commit `feat(store): FTS5 index maintenance in-transaction (stub/reindex/delete) + integrity-check`.

---

### Task 4: Attachments metadata + has_attachment at hydrate

**Files:**
- Modify: `Sources/GmailKit/API/Models/GmailMessage.swift` (attachment extraction), `Sources/Store/StoreBodies.swift` (`saveBody` also writes attachments + sets `has_attachment`), `Sources/SyncEngine/SyncEngine.swift` (`hydrateBodies` passes attachment metadata)
- Test: `Tests/GmailKitTests/AttachmentExtractionTests.swift`, `Tests/StoreTests/AttachmentStoreTests.swift`

**Interfaces:**
- Produces:
  - `GmailMessage.attachments() -> [(attachmentID: String, filename: String, mimeType: String, size: Int)]` — walks the part tree collecting parts with a non-empty `filename` and a `body.attachmentId`.
  - `HudsonDatabase.saveBody(...)` gains an `attachments: [AttachmentMeta]` parameter (struct `public struct AttachmentMeta: Sendable { id, filename, mimeType: String; size: Int }`); it upserts `attachments` rows and sets `messages.has_attachment = (attachments non-empty)` in the same transaction. `SyncEngine.hydrateBodies` computes `message.attachments()` and passes them.
  - `has_attachment` is eventually-consistent (metadata backfill has no attachment field — only the `format:"full"` hydration does), documented.

- [ ] **Steps:** RED (extract attachments from a multipart fixture; saveBody sets has_attachment + attachments rows) → implement → GREEN → commit `feat(store,gmailkit): attachment metadata + has_attachment at hydration`.

---

### Task 5: Inbox query API (rollup-backed, overlay-composed, keyset)

**Files:**
- Create: `Sources/Store/InboxQuery.swift`
- Test: `Tests/StoreTests/InboxQueryTests.swift`

**Interfaces:**
- Produces:
  - `public struct ThreadRow: Sendable, Equatable { public let threadID, lastMessageID, subject, snippet, fromSummary, splitKey, category: String; public let lastMessageAt: Int64; public let messageCount: Int; public let unread, inInbox, hasAttachment: Bool }`
  - `func inboxThreads(account: String, split: String?, limit: Int, before: (lastMessageAt: Int64, threadID: String)? = nil) async throws -> [ThreadRow]` — reads `thread_rollup` ONLY, `WHERE account_email=? AND in_inbox=1 [AND split_key=?] ORDER BY last_message_at DESC, thread_id DESC LIMIT ?` with keyset pagination via `before`. **Overlay-composed:** `in_inbox` on the rollup is server-truth; the effective inbox membership must subtract threads whose newest message has a pending INBOX-remove and add pending INBOX-adds. Simplest correct approach: the rollup's `in_inbox` is recomputed by `recomputeThreadFlags` (Task 2) which is already overlay-aware, so `thread_rollup.in_inbox` already reflects the overlay after a triage enqueue calls the recompute. **Ensure `enqueueMutation` (M3) triggers `recomputeThreadFlags` for the affected thread** so the rollup's in_inbox/unread reflect the optimistic action instantly (this is the M3↔M4 seam — add it).
  - `has_attachment` joins from `messages` on `last_message_id` (or denormalize onto the rollup — pick denormalize for zero-join, maintained in Task 2/4). Keep it on the rollup: add `has_attachment` to `thread_rollup` maintained from the last message.

- [ ] **Steps:** RED (inbox list newest-first, split filter, a pending-archived thread drops from the list, keyset pagination) → implement → GREEN → commit `feat(store): rollup-backed inbox query with overlay + keyset pagination`.

**Note (M3↔M4 seam):** this task wires `enqueueMutation`/`retire` to call `ThreadRollup.recomputeThreadFlags` for the touched thread, so optimistic triage updates the inbox list instantly. Add a test: archive the only message in a thread → `inboxThreads` no longer returns it.

---

### Task 6: FTS search query API (bm25, overlay JOIN, char floor)

**Files:**
- Create: `Sources/Store/SearchQuery.swift`
- Test: `Tests/StoreTests/SearchQueryTests.swift`

**Interfaces:**
- Produces:
  - `public struct SearchHit: Sendable, Equatable { public let messageID, threadID, subject, fromLine, snippet: String; public let internalDate: Int64 }`
  - `func searchMessages(account: String, query: String, limit: Int) async throws -> [SearchHit]` — a `writer.read`; enforces a **2-char minimum** (returns `[]` below it); builds an FTS5 MATCH (prefix-appended terms, sanitized against FTS syntax injection — escape `"`), `ORDER BY bm25(fts_messages, <col weights subject/from over body>) LIMIT ?`; joins back to `messages` via `message_seq`; **composes the M3 overlay** so a hit that has been optimistically archived is filtered when the caller asks for in-inbox scope (add a `scope: SearchScope = .all` with `.all`/`.inbox`; `.inbox` applies the effective-INBOX overlay). Column weights: `bm25(fts_messages, 10.0, 5.0, 2.0, 1.0)` (subject, from, to, body).
  - Debouncing/cancellation is a CLI/UI concern (Task 9 / UI phase) — the Store provides the fast bounded read.

- [ ] **Steps:** RED (search finds by subject+body, ranks subject over body, prefix `quart*` matches, sub-2-char returns empty, an archived hit excluded under `.inbox` scope, FTS-syntax chars don't crash) → implement → GREEN → commit `feat(store): FTS bm25 search with overlay scope + query-floor + injection-safe MATCH`.

---

### Task 7: Split inbox — split_rules + split_key computation + CATEGORY_* free

**Files:**
- Create: `Sources/Store/SplitInbox.swift`
- Modify: `Sources/Store/ThreadRollup.swift` (compute `split_key`/`category` during maintenance)
- Test: `Tests/StoreTests/SplitInboxTests.swift`, `Tests/SyncEngineTests/CategoryPersistenceTests.swift`

**Interfaces:**
- Produces:
  - `public struct SplitRule: Sendable { public let ordinal: Int; public let kind: SplitPredicateKind; public let value, splitName: String }`, `enum SplitPredicateKind: String { case sender, domain, listid, category }`
  - `func setSplitRules(_ rules: [SplitRule], account: String) async throws` / `func splitRules(account: String) async throws -> [SplitRule]` (CRUD on `split_rules`, ordered).
  - `static func computeSplit(fromLine: String, listID: String?, categoryLabels: [String], rules: [SplitRule]) -> (splitKey: String, category: String)` — pure: first matching ordered rule wins → `split_key = rule.splitName`; `category` = the message's `CATEGORY_*` label (mapped to a friendly name: `CATEGORY_PROMOTIONS`→`promotions`, etc.); if no rule matches, `split_key` defaults to the category (so **Gmail categories give split tabs for free**) else `'primary'`.
  - Maintenance (Task 2's `maintainRollup`) calls `computeSplit` for the thread's newest message and writes `split_key`/`category` onto the rollup. Rules are loaded once per maintenance batch (cache on the account) — do NOT re-query per message.
- CATEGORY persistence test (SyncEngineTests): drive a `ScriptedGmail` sync of a message carrying `CATEGORY_PROMOTIONS`; assert the label persists through `applySnapshot` and the rollup's `category`/`split_key` reflects it — proving category splits need zero extra sync work.

- [ ] **Steps:** RED → implement → GREEN → commit `feat(store): split_rules + split_key computation; Gmail categories split for free`.

---

### Task 8: AIKit pre-M7 hooks (ai_artifacts/ai_config APIs, LLMKeyStore, thread/sent reads)

**Files:**
- Create: `Sources/Store/AIArtifacts.swift`, `Sources/Store/AIStore.swift`, `Sources/GmailKit/OAuth/LLMKeyStore.swift`
- Test: `Tests/StoreTests/AIStoreTests.swift`, `Tests/GmailKitTests/LLMKeyStoreTests.swift`

**Interfaces:**
- Produces (Store):
  - `func putArtifact(kind:key:model:promptVersion:content:sources:account:createdAt:) async throws` / `func artifact(kind:key:model:promptVersion:account:) async throws -> String?` — content-addressed cache; `sources: [String]` message-ids recorded in `ai_artifact_sources` for purge-on-delete (extend `deleteVanishedMessage`/purge to delete artifacts whose sources include the id).
  - `func aiConfig(feature:account:) async throws -> (model: String, baseURL: String?, optIn: Bool)?` / `func setAIConfig(...)`.
  - `func threadMessages(threadID:account:) async throws -> [MessageRow]` (ordered, for summarize/draft context), `func sentMessages(account:limit:) async throws -> [MessageRow]` (SENT label, for the voice profile). Both overlay-aware and body-joined where needed.
- Produces (GmailKit — mirrors TokenStore seam, so CI never touches a real keychain):
  - `public protocol LLMKeyStore: Sendable { func saveKey(_ key: String, provider: String) throws; func key(provider: String) throws -> String?; func deleteKey(provider: String) throws }`
  - `public final class InMemoryLLMKeyStore: LLMKeyStore` (tests) and `public struct KeychainLLMKeyStore: LLMKeyStore` (service `"com.hudson.llm"`) — same shape as the existing TokenStore/KeychainTokenStore.
- No LLM providers or egress here (that's M7) — this is only the storage/config/retrieval seam so M7 grafts cleanly.

- [ ] **Steps:** RED → implement → GREEN → commit `feat(store,gmailkit): AIKit pre-hooks — ai_artifacts/config, thread/sent reads, LLMKeyStore seam`.

---

### Task 9: CLI — `search`, `inbox --split`; wire read-only via LocalRuntime

**Files:**
- Create: `Sources/HudsonCLI/SearchCommand.swift`, `Sources/HudsonCLI/InboxCommand.swift`
- Modify: `Sources/HudsonCLI/HudsonCommand.swift` (register); `Sources/HudsonCLI/ListCommand.swift` (optional: point `list` at `inboxThreads` for thread-grouped output — keep `list` message-flat for now, add `inbox` as the thread view)
- Modify: `Tests/HudsonCLITests/RuntimeLocalTests.swift` (fold M3 minor: use `ProcessInfo.processInfo.globallyUniqueString` for the temp dir)
- Test: `Tests/HudsonCLITests/SearchInboxCommandTests.swift` (if a LocalRuntime seam allows; else manual)

**Interfaces:**
- `hudson search <query> [--limit N] [--inbox]` — via `LocalRuntime.local()` (no Keychain), `searchMessages`, prints hits; all message-derived fields through `Sanitizer.terminalSafe(_, singleLine: true)`; enforces the 2-char floor with a friendly message.
- `hudson inbox [--split <name>] [--limit N]` — via `LocalRuntime.local()`, `inboxThreads`, prints thread rows (unread dot, from summary, subject, count); split filter; sanitized output.
- Fold the M3-deferred `RuntimeLocalTests` temp-path minor here (globallyUniqueString).

- [ ] **Steps:** implement thin commands (ProfileCommand/reportAndFail pattern) + register + fix the temp-path minor; `swift build` zero-warnings + full `swift test`; record the PENDING-OPERATOR live sequence (`hudson sync` → `hudson search <term>` → `hudson inbox --split promotions`) in the report → commit `feat(cli): hudson search + inbox --split (LocalRuntime, sanitized)`.

---

### Task 10: Docs — spec §3/§3.4/§11, README

**Files:**
- Modify: `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` (§11 M4 → DONE; §3 note the rollup/FTS/split as built), `README.md` (quickstart: `search`, `inbox --split`)

- [ ] **Steps:** update §11 M4 bullet to `**M4 — DONE**`; README Try section gains `hudson search <term>` and `hudson inbox --split <name>`; verify commands via `--help`; commit `docs: spec/README for M4 query layer`.

---

## Self-Review (completed at plan-writing time)

1. **Design coverage:** rollup schema+bulk-build (T1); O(1) incremental maintenance + unread recompute (T2, the biggest-risk item — has the large-thread test); FTS5 maintenance in-transaction + integrity-check (T3); attachments + has_attachment at hydrate (T4); rollup-backed overlay-composed keyset inbox query + N+1 elimination + the M3↔M4 recompute seam (T5); bm25 search + overlay scope + char floor + injection-safe MATCH (T6); split_rules + split_key + CATEGORY_* free + persistence test (T7); AIKit pre-hooks incl. LLMKeyStore seam + ai_artifacts purge (T8); CLI search/inbox + RuntimeLocalTests temp-path minor (T9); docs (T10). Folded M3-deferred minors: LabelOp CHECK (T1 trigger), busyMode comment (T1), RuntimeLocalTests temp path (T9).
2. **Placeholder scan:** no TBDs. Tasks 2–4 tests may read `thread_rollup` directly to stay self-contained before `inboxThreads` (T5) exists — noted in T2. The FTS `prefix='2 3 4'` / 2-char floor, bm25 weights, and category name mapping are concrete.
3. **Type consistency:** `ThreadRow`, `SearchHit`, `AttachmentMeta`, `SplitRule`/`SplitPredicateKind`, `inboxThreads`, `searchMessages`, `maintainRollup`/`recomputeThreadFlags`, `stubIndex`/`reindexBody`/`deleteIndex`/`seq`, `computeSplit`, `LLMKeyStore`/`InMemoryLLMKeyStore`, `putArtifact`/`artifact`, `threadMessages`/`sentMessages` are used with consistent signatures across defining/consuming tasks. `applySnapshotInTransaction` gains a `wasInsert` determination (T2) consumed by rollup + FTS stub. The M3↔M4 seam (enqueueMutation/retire → recomputeThreadFlags) is called out in T5.
