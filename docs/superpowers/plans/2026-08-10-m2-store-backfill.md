# M2 — Store + Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `hudson sync` downloads the user's real mailbox into a local GRDB store — resumable, quota-paced, converging under concurrent history events — and `hudson list` / `hudson show` read it back instantly from disk.

**Architecture:** Two new SPM targets: `Store` (GRDB persistence, versioned writes, tombstones, sanitizer pipeline — knows nothing of the network) and `SyncEngine` (the only module composing GmailKit + Store: backfill, history polling, body hydration, single-flight discipline). GmailKit gains the three read endpoints (`messages.list`, `messages.get`, `history.list`) plus MIME-part extraction. The CLI grows `sync`/`list`/`show` and migrates account records from `accounts.json` into the database.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, GRDB.swift 7 (second and last M2 dependency — spec §3 mandates it), swift-argument-parser.

## Global Constraints

_(spec `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` — every task inherits these)_

- Swift 6 language mode, macOS 15+. Dependencies: swift-argument-parser + **GRDB.swift only** (spec §3).
- **Dependency rule (spec §2):** `Store` never imports GmailKit or networking; `GmailKit` never imports GRDB; only `SyncEngine` composes both; CLI uses public APIs only.
- **Sync invariants (spec §4):** reads never block on the network; the store converges to server state; every snapshot write goes through the per-message historyId version guard (§4.2); tombstoned ids reject snapshot inserts; history events apply in order with the cursor advance in the same transaction, no `await` between apply and cursor update (§4.3).
- **Quota (spec §4.5):** bucket 5,500 units/min; costs: `messages.get` = 20, `messages.list` = 5, `history.list` = 2, `labels.list` = 1, `getProfile` = 1. Backfill must be resumable and interruption-safe.
- **Concurrency (spec §4.6):** at most one sync pass in flight per account; cross-`await` state lives in SQLite, not actor memory; synchronous GRDB `write`/`read` calls from actor-isolated code are banned — async GRDB APIs only.
- **Untrusted content (spec §3.5):** raw HTML stored as opaque bytes, never interpreted; one sanitizer derives plain text for all display; every message-derived string printed to the terminal is stripped of C0/C1 controls and ANSI/OSC escapes; `sanitizer_version` recorded on every body row.
- **Never-log list (spec §9.1):** no tokens, secrets, message bodies/snippets/subjects in logs; network logs carry method + **path template** (never the actual path once ids are embedded) + status.
- **Readability bar:** doc comments on every public type and method (initializers included), descriptive names, files ~200 lines, no dead code, pristine test output.
- TDD: failing test first, RED evidence, then implement, GREEN evidence, commit per task.
- **M1-inherited obligations are Tasks 1, 2, 5, 6 — they are not optional.**

---

### Task 1: GmailKit polish — path-template logging + JSON rate-limit reason

_(M1 obligations: path-template logging before id-bearing endpoints; `bodyIndicatesRateLimit` parsing the JSON reason field.)_

**Files:**
- Modify: `Sources/GmailKit/Transport/GmailError.swift` (replace `bodyIndicatesRateLimit`)
- Modify: `Sources/GmailKit/API/GmailClient.swift` (add `template:` to the request core; log template only)
- Test: `Tests/GmailKitTests/GmailErrorTests.swift` (add cases)
- Test: `Tests/GmailKitTests/GmailClientTests.swift` (unchanged tests must still pass)

**Interfaces:**
- Consumes: existing `GmailError.from(status:data:retryAfterHeader:)`, `GmailClient.get`.
- Produces: `GmailClient` internal request core with signature `get<Response: Decodable>(template: String, path: String, query: [URLQueryItem] = [], cost: Int) async throws -> Response` — **all later tasks' endpoints call this**. `getProfile()` becomes `get(template: "users/me/profile", path: "users/me/profile", cost: GmailQuotaCost.getProfile)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/GmailKitTests/GmailErrorTests.swift`:

```swift
@Test func rateLimit403RequiresReasonField() {
    // The literal string outside the reason field must NOT classify as rate limiting.
    let decoy = #"{"error": {"message": "try rateLimitExceeded backoff", "errors": [{"reason": "forbidden"}]}}"#
    let error = GmailError.from(status: 403, data: Data(decoy.utf8), retryAfterHeader: nil)
    #expect(error == .invalidRequest(status: 403, message: "try rateLimitExceeded backoff"))
}

@Test func rateLimit403MatchesUserRateLimitReason() {
    let body = #"{"error": {"errors": [{"reason": "userRateLimitExceeded"}]}}"#
    #expect(GmailError.from(status: 403, data: Data(body.utf8), retryAfterHeader: nil)
        == .rateLimited(retryAfter: nil))
}
```

- [ ] **Step 2: Run tests to verify the first fails**

Run: `swift test --filter GmailErrorTests`
Expected: `rateLimit403RequiresReasonField` FAILS (substring match wrongly classifies the decoy); the other passes.

- [ ] **Step 3: Implement**

In `GmailError.swift`, replace `bodyIndicatesRateLimit` with a JSON decode:

```swift
    private static func bodyIndicatesRateLimit(_ data: Data) -> Bool {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                struct Item: Decodable { let reason: String? }
                let errors: [Item]?
            }
            let error: Inner?
        }
        let reasons = (try? JSONDecoder().decode(Envelope.self, from: data))?
            .error?.errors?.compactMap(\.reason) ?? []
        return reasons.contains("rateLimitExceeded") || reasons.contains("userRateLimitExceeded")
    }
```

In `GmailClient.swift`, change the request core (keep retry/backoff/token logic identical):

```swift
    private func get<Response: Decodable>(
        template: String, path: String, query: [URLQueryItem] = [], cost: Int
    ) async throws -> Response {
```

Build the URL from `path` + `query` (`URLComponents` over `Self.baseURL.appending(path: path)`), and change the log line to the template only:

```swift
            Log.transport.info("GET \(template, privacy: .public) -> \(response.statusCode)")
```

Add a doc comment on the core: `/// template is what gets logged (never the actual path — ids in paths would violate spec §9.1); path is what gets requested.` Update `getProfile()` to the new signature.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: 42/42 pass (40 prior + 2 new).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "fix(gmailkit): JSON reason parsing for 403 rate limits; path-template logging"
```

---

### Task 2: QuotaBucket — FIFO ticket queue

_(M1 obligation: the parked non-FIFO starvation finding. Large-cost acquirers must not starve behind sustained small-cost traffic.)_

**Files:**
- Modify: `Sources/GmailKit/Transport/QuotaBucket.swift`
- Test: `Tests/GmailKitTests/QuotaBucketTests.swift` (existing 3 tests must keep passing; add 2)

**Interfaces:**
- Consumes/Produces: public API unchanged — `init(unitsPerMinute:now:sleep:)`, `acquire(cost:) async throws`. Only the internal wait discipline changes to strict FIFO.

- [ ] **Step 1: Write the failing test**

Append to `Tests/GmailKitTests/QuotaBucketTests.swift` (reuse the existing `VirtualClock`):

```swift
@Test func acquirersAreServedStrictlyInArrivalOrder() async throws {
    let clock = VirtualClock()
    let bucket = QuotaBucket(unitsPerMinute: 100, now: { clock.now }, sleep: { clock.sleep($0) })
    try await bucket.acquire(cost: 90)  // window nearly full

    let order = LockedOrder()
    // Big request first — it doesn't fit yet. Small request second — it WOULD fit,
    // but FIFO means it must wait behind the big one.
    async let big: Void = {
        try await bucket.acquire(cost: 50)
        order.append("big")
    }()
    try await Task.sleep(for: .milliseconds(50))  // real sleep: let `big` enqueue first
    async let small: Void = {
        try await bucket.acquire(cost: 5)
        order.append("small")
    }()
    _ = try await (big, small)
    #expect(order.values == ["big", "small"])
}

@Test func fifoStillRejectsOversizedCost() async {
    let bucket = QuotaBucket(unitsPerMinute: 100)
    await #expect(throws: GmailError.self) { try await bucket.acquire(cost: 101) }
}

/// Thread-safe ordered event log for the FIFO test.
private final class LockedOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
    var values: [String] { lock.withLock { events } }
}
```

- [ ] **Step 2: Run tests to verify the FIFO test fails**

Run: `swift test --filter QuotaBucketTests`
Expected: `acquirersAreServedStrictlyInArrivalOrder` FAILS (small jumps the queue under the recheck-loop design); others pass.

- [ ] **Step 3: Implement the ticket queue**

Replace the wait loop in `QuotaBucket.swift` with a FIFO waiter queue drained by a single task:

```swift
public actor QuotaBucket {
    private let unitsPerMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var spends: [(date: Date, cost: Int)] = []
    /// FIFO queue: heads are served strictly before later arrivals, even when
    /// a later, cheaper request would fit sooner (prevents starvation of
    /// large-cost calls like messages.send behind polling traffic).
    private var waiters: [(cost: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var isDraining = false

    // init unchanged …

    /// Waits until `cost` units fit in the rolling window, then records them.
    /// Service order is strict FIFO.
    public func acquire(cost: Int) async throws {
        guard cost <= unitsPerMinute else {
            throw GmailError.invalidRequest(
                status: 0,
                message: "Quota cost \(cost) exceeds the per-minute budget of \(unitsPerMinute).")
        }
        pruneExpiredSpends()
        if waiters.isEmpty && spentInWindow() + cost <= unitsPerMinute {
            spends.append((now(), cost))
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((cost, continuation))
            if !isDraining {
                isDraining = true
                Task { await self.drain() }
            }
        }
    }

    /// Serves waiters in order; sleeps until the head's cost fits, grants it,
    /// moves on. Only ever one drain task (isDraining), so order is stable.
    private func drain() async {
        while let head = waiters.first {
            pruneExpiredSpends()
            if spentInWindow() + head.cost <= unitsPerMinute {
                spends.append((now(), head.cost))
                waiters.removeFirst().continuation.resume()
                continue
            }
            let oldest = spends[0].date  // non-empty: head doesn't fit, so something is spent
            let wait = max(60 - now().timeIntervalSince(oldest), 0.05)
            do { try await sleep(wait) } catch {
                // Sleep failure (cancellation) — fail every waiter rather than hang.
                while let waiter = waiters.first {
                    waiters.removeFirst()
                    waiter.continuation.resume(throwing: error)
                }
            }
        }
        isDraining = false
    }

    private func spentInWindow() -> Int { spends.reduce(0) { $0 + $1.cost } }

    private func pruneExpiredSpends() {
        let cutoff = now().addingTimeInterval(-60)
        spends.removeAll { $0.date <= cutoff }
    }
}
```

Keep `GmailQuotaCost` unchanged but add `public static let labelsList = 1`.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all pass, including the three pre-existing QuotaBucket tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "fix(gmailkit): FIFO ticket queue in QuotaBucket — no starvation of large-cost calls"
```

---

### Task 3: Store target — GRDB dependency, database bootstrap, schema v1

**Files:**
- Modify: `Package.swift` (GRDB dependency; `Store` target + `StoreTests`)
- Create: `Sources/Store/HudsonDatabase.swift`
- Create: `Sources/Store/Migrations.swift`
- Test: `Tests/StoreTests/MigrationTests.swift`

**Interfaces:**
- Consumes: nothing from GmailKit (dependency rule).
- Produces:
  - `public struct HudsonDatabase: Sendable` — `public let writer: any DatabaseWriter`; `public static func open(at url: URL) throws -> HudsonDatabase` (creates parent directory, runs migrations); `public static func inMemory() throws -> HudsonDatabase` (tests).
  - Schema v1 tables (all account-scoped): `accounts`, `threads`, `messages` (with `history_id INTEGER NOT NULL`), `message_bodies`, `labels`, `message_labels`, `tombstones`.

- [ ] **Step 1: Add the dependency and targets to Package.swift**

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
```

New targets (and add `"Store"` to `HudsonCLI`'s dependencies):

```swift
        .target(name: "Store", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
```

- [ ] **Step 2: Write the failing test**

`Tests/StoreTests/MigrationTests.swift`:

```swift
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter MigrationTests`
Expected: FAIL — `HudsonDatabase` not defined.

- [ ] **Step 4: Implement**

`Sources/Store/HudsonDatabase.swift`:

```swift
import Foundation
import GRDB

/// The one handle to Hudson's local SQLite store. All writes flow through
/// GRDB's single writer queue; reads use snapshots. Actor code must use the
/// async GRDB APIs only (spec §4.6) — synchronous write/read from an actor
/// blocks a cooperative-pool thread.
public struct HudsonDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the store at `url` and migrates to the
    /// current schema. The parent directory is created if missing.
    public static func open(at url: URL) throws -> HudsonDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator.migrate(pool)
        return HudsonDatabase(writer: pool)
    }

    /// In-memory store for tests — same schema, no disk.
    public static func inMemory() throws -> HudsonDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue)
        return HudsonDatabase(writer: queue)
    }
}
```

`Sources/Store/Migrations.swift`:

```swift
import GRDB

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

    return migrator
}()
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MigrationTests`
Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(store): GRDB dependency, database bootstrap, schema v1"
```

---

### Task 4: Store writes — version guard, tombstones, history application, reads

**Files:**
- Create: `Sources/Store/MessageSnapshot.swift`
- Create: `Sources/Store/StoreWrites.swift`
- Create: `Sources/Store/StoreReads.swift`
- Test: `Tests/StoreTests/VersionGuardTests.swift`
- Test: `Tests/StoreTests/HistoryApplyTests.swift`

**Interfaces:**
- Consumes: `HudsonDatabase` (Task 3).
- Produces (all methods `async` on `HudsonDatabase`, implemented with GRDB's async `writer.write`):
  - `public struct MessageSnapshot: Sendable, Equatable` — `id, threadID: String`, `historyID: Int64`, `internalDate: Int64` (ms), `fromLine, toLine, subject, snippet: String`, `labelIDs: [String]`, memberwise init.
  - `public enum SnapshotOutcome: Sendable, Equatable { case applied, stale, tombstoned }`
  - `func applySnapshot(_ snapshot: MessageSnapshot, account: String) async throws -> SnapshotOutcome`
  - `public struct HistoryChange: Sendable` — `enum Kind { case added(MessageSnapshot), deleted(id: String), labels(id: String, historyID: Int64, labelIDs: [String]) }`, `let kind: Kind`
  - `func applyHistory(_ changes: [HistoryChange], newCursor: Int64, account: String) async throws -> [String]` — applies in order in ONE transaction, advances `accounts.history_cursor`, returns unknown message ids needing hydration (spec §4.1).
  - `func saveBody(messageID: String, account: String, body: SanitizedBody) async throws` *(SanitizedBody arrives in Task 7 — this task stubs the signature with the struct defined there; implement `saveBody` in Task 7 instead if you prefer — but the row update `has_body = true` lives here as `markBodySaved`)*. **Correction for implementers: `saveBody` is Task 7's. This task produces only the snapshot/history/read APIs below.**
  - `func upsertLabels(_ labels: [(id: String, name: String)], account: String) async throws`
  - `public struct MessageRow: Sendable, Equatable` — mirrors the `messages` columns (`id, threadID, historyID, internalDate, fromLine, toLine, subject, snippet, hasBody, labelIDs: [String]`). (Hand-built from rows — `labelIDs` needs a second query, so `FetchableRecord` is deliberately not used.)
  - `func recentMessages(account: String, limit: Int) async throws -> [MessageRow]` (newest first, tombstones excluded)
  - `func message(id: String, account: String) async throws -> (row: MessageRow, plainText: String?)?`

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/VersionGuardTests.swift`:

```swift
import Testing
@testable import Store

private func snapshot(
    id: String = "m1", historyID: Int64, labels: [String] = ["INBOX"]
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: "t1", historyID: historyID, internalDate: 1_000,
        fromLine: "a@example.com", toLine: "b@example.com",
        subject: "s", snippet: "sn", labelIDs: labels)
}

@Test func newerSnapshotApplies() async throws {
    let database = try HudsonDatabase.inMemory()
    #expect(try await database.applySnapshot(snapshot(historyID: 5), account: "x") == .applied)
    #expect(try await database.applySnapshot(snapshot(historyID: 9), account: "x") == .applied)
    let rows = try await database.recentMessages(account: "x", limit: 10)
    #expect(rows.first?.historyID == 9)
}

@Test func staleSnapshotIsDiscarded() async throws {
    let database = try HudsonDatabase.inMemory()
    _ = try await database.applySnapshot(snapshot(historyID: 9, labels: ["ARCHIVED"]), account: "x")
    // A late-arriving older snapshot (e.g. slow backfill get racing a newer
    // history event) must NOT clobber the newer label state — spec §4.2.
    #expect(try await database.applySnapshot(snapshot(historyID: 5), account: "x") == .stale)
    let rows = try await database.recentMessages(account: "x", limit: 10)
    #expect(rows.first?.labelIDs == ["ARCHIVED"])
}

@Test func tombstonedIdRejectsSnapshots() async throws {
    let database = try HudsonDatabase.inMemory()
    _ = try await database.applyHistory(
        [HistoryChange(kind: .deleted(id: "m1"))], newCursor: 4, account: "x")
    // A backfill page listing the deleted message arrives late — it must not resurrect.
    #expect(try await database.applySnapshot(snapshot(historyID: 3), account: "x") == .tombstoned)
    #expect(try await database.recentMessages(account: "x", limit: 10).isEmpty)
}
```

`Tests/StoreTests/HistoryApplyTests.swift`:

```swift
import GRDB
import Testing
@testable import Store

@Test func historyAppliesInOrderAndAdvancesCursor() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: """
            INSERT INTO accounts (email, client_id, consented_at) VALUES ('x', 'c', 0)
            """)
    }
    let added = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 10, internalDate: 1_000,
        fromLine: "a@ex.com", toLine: "b@ex.com", subject: "s", snippet: "sn",
        labelIDs: ["INBOX", "UNREAD"])
    let unknown = try await database.applyHistory([
        HistoryChange(kind: .added(added)),
        HistoryChange(kind: .labels(id: "m1", historyID: 11, labelIDs: ["INBOX"])),  // read
        HistoryChange(kind: .labels(id: "ghost", historyID: 12, labelIDs: ["INBOX"])),
    ], newCursor: 12, account: "x")

    #expect(unknown == ["ghost"])  // unknown id surfaced for hydration, not applied blind
    let row = try #require(try await database.recentMessages(account: "x", limit: 1).first)
    #expect(row.labelIDs == ["INBOX"])   // UNREAD removed by the later event
    #expect(row.historyID == 11)
    let cursor = try await database.writer.read { db in
        try Int64.fetchOne(db, sql: "SELECT history_cursor FROM accounts WHERE email='x'")
    }
    #expect(cursor == 12)
}

@Test func deletionTombstonesAndRemoves() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO accounts (email, client_id, consented_at) VALUES ('x','c',0)")
    }
    let added = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 10, internalDate: 1_000,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: ["INBOX"])
    _ = try await database.applyHistory(
        [HistoryChange(kind: .added(added))], newCursor: 10, account: "x")
    _ = try await database.applyHistory(
        [HistoryChange(kind: .deleted(id: "m1"))], newCursor: 11, account: "x")
    #expect(try await database.recentMessages(account: "x", limit: 10).isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VersionGuardTests && swift test --filter HistoryApplyTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement**

`Sources/Store/MessageSnapshot.swift`:

```swift
/// One message's server-state snapshot, as SyncEngine hands it to the Store.
/// `historyID` is Gmail's per-message version — the §4.2 anti-clobber guard.
public struct MessageSnapshot: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let historyID: Int64
    public let internalDate: Int64
    public let fromLine: String
    public let toLine: String
    public let subject: String
    public let snippet: String
    public let labelIDs: [String]

    /// Memberwise — SyncEngine maps Gmail DTOs into this.
    public init(
        id: String, threadID: String, historyID: Int64, internalDate: Int64,
        fromLine: String, toLine: String, subject: String, snippet: String,
        labelIDs: [String]
    ) {
        self.id = id
        self.threadID = threadID
        self.historyID = historyID
        self.internalDate = internalDate
        self.fromLine = fromLine
        self.toLine = toLine
        self.subject = subject
        self.snippet = snippet
        self.labelIDs = labelIDs
    }
}

/// What happened to a snapshot write (spec §4.2).
public enum SnapshotOutcome: Sendable, Equatable {
    case applied
    /// Discarded: the store already holds a newer version of this message.
    case stale
    /// Discarded: the message was deleted; late snapshots must not resurrect it.
    case tombstoned
}

/// One ordered change from Gmail's history feed.
public struct HistoryChange: Sendable {
    public enum Kind: Sendable {
        case added(MessageSnapshot)
        case deleted(id: String)
        /// Label state after the event, with the history record's id as version.
        case labels(id: String, historyID: Int64, labelIDs: [String])
    }
    public let kind: Kind

    /// Wraps one change; order within the array passed to `applyHistory` matters.
    public init(kind: Kind) { self.kind = kind }
}
```

`Sources/Store/StoreWrites.swift`:

```swift
import Foundation
import GRDB

extension HudsonDatabase {
    /// Writes a snapshot through the §4.2 version guard. Inside one
    /// transaction: tombstone check → history_id comparison → upsert.
    public func applySnapshot(
        _ snapshot: MessageSnapshot, account: String
    ) async throws -> SnapshotOutcome {
        try await writer.write { db in
            try Self.applySnapshotInTransaction(snapshot, account: account, db: db)
        }
    }

    /// Applies history changes in order and advances the cursor — all in ONE
    /// transaction, so a crash resumes cleanly from the stored cursor (§4.3).
    /// Returns ids of label events targeting unknown messages: the caller
    /// hydrates them (dropping would also be safe under the version guard —
    /// spec §4.1 — but hydration converges faster).
    public func applyHistory(
        _ changes: [HistoryChange], newCursor: Int64, account: String
    ) async throws -> [String] {
        try await writer.write { db in
            var unknownIDs: [String] = []
            for change in changes {
                switch change.kind {
                case .added(let snapshot):
                    _ = try Self.applySnapshotInTransaction(snapshot, account: account, db: db)
                case .deleted(let id):
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO tombstones (account_email, message_id) VALUES (?, ?)",
                        arguments: [account, id])
                    try db.execute(
                        sql: "DELETE FROM messages WHERE account_email = ? AND id = ?",
                        arguments: [account, id])
                case .labels(let id, let historyID, let labelIDs):
                    let exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE account_email = ? AND id = ?)",
                        arguments: [account, id]) ?? false
                    guard exists else {
                        unknownIDs.append(id)
                        continue
                    }
                    let stored = try Int64.fetchOne(
                        db,
                        sql: "SELECT history_id FROM messages WHERE account_email = ? AND id = ?",
                        arguments: [account, id]) ?? 0
                    guard historyID >= stored else { continue }
                    try db.execute(
                        sql: "UPDATE messages SET history_id = ? WHERE account_email = ? AND id = ?",
                        arguments: [historyID, account, id])
                    try Self.replaceLabels(labelIDs, messageID: id, account: account, db: db)
                }
            }
            try db.execute(
                sql: "UPDATE accounts SET history_cursor = ? WHERE email = ?",
                arguments: [newCursor, account])
            return unknownIDs
        }
    }

    /// Caches Gmail's label id→name mapping for display.
    public func upsertLabels(
        _ labels: [(id: String, name: String)], account: String
    ) async throws {
        try await writer.write { db in
            for label in labels {
                try db.execute(
                    sql: """
                        INSERT INTO labels (account_email, id, name) VALUES (?, ?, ?)
                        ON CONFLICT(account_email, id) DO UPDATE SET name = excluded.name
                        """,
                    arguments: [account, label.id, label.name])
            }
        }
    }

    // MARK: - Transaction bodies (synchronous, called inside writer.write)

    static func applySnapshotInTransaction(
        _ snapshot: MessageSnapshot, account: String, db: Database
    ) throws -> SnapshotOutcome {
        let tombstoned = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM tombstones WHERE account_email = ? AND message_id = ?)",
            arguments: [account, snapshot.id]) ?? false
        if tombstoned { return .tombstoned }

        if let stored = try Int64.fetchOne(
            db,
            sql: "SELECT history_id FROM messages WHERE account_email = ? AND id = ?",
            arguments: [account, snapshot.id]), stored > snapshot.historyID {
            return .stale
        }

        try db.execute(
            sql: """
                INSERT INTO threads (account_email, id, last_message_at) VALUES (?, ?, ?)
                ON CONFLICT(account_email, id)
                DO UPDATE SET last_message_at = MAX(last_message_at, excluded.last_message_at)
                """,
            arguments: [account, snapshot.threadID, snapshot.internalDate])
        try db.execute(
            sql: """
                INSERT INTO messages (account_email, id, thread_id, history_id, internal_date,
                                      from_line, to_line, subject, snippet)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_email, id) DO UPDATE SET
                    history_id = excluded.history_id,
                    thread_id = excluded.thread_id,
                    internal_date = excluded.internal_date,
                    from_line = excluded.from_line,
                    to_line = excluded.to_line,
                    subject = excluded.subject,
                    snippet = excluded.snippet
                """,
            arguments: [
                account, snapshot.id, snapshot.threadID, snapshot.historyID,
                snapshot.internalDate, snapshot.fromLine, snapshot.toLine,
                snapshot.subject, snapshot.snippet,
            ])
        try replaceLabels(snapshot.labelIDs, messageID: snapshot.id, account: account, db: db)
        return .applied
    }

    static func replaceLabels(
        _ labelIDs: [String], messageID: String, account: String, db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM message_labels WHERE account_email = ? AND message_id = ?",
            arguments: [account, messageID])
        for labelID in labelIDs {
            try db.execute(
                sql: "INSERT INTO message_labels (account_email, message_id, label_id) VALUES (?, ?, ?)",
                arguments: [account, messageID, labelID])
        }
    }
}
```

`Sources/Store/StoreReads.swift`:

```swift
import Foundation
import GRDB

/// One row of the message list — what the CLI (and later the UI) renders.
public struct MessageRow: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let historyID: Int64
    public let internalDate: Int64
    public let fromLine: String
    public let toLine: String
    public let subject: String
    public let snippet: String
    public let hasBody: Bool
    public let labelIDs: [String]
}

extension HudsonDatabase {
    /// Newest-first message list. Reads SQLite only — never the network (§4 invariant 3).
    public func recentMessages(account: String, limit: Int) async throws -> [MessageRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages WHERE account_email = ?
                    ORDER BY internal_date DESC LIMIT ?
                    """,
                arguments: [account, limit])
            return try rows.map { try Self.messageRow(from: $0, account: account, db: db) }
        }
    }

    /// One message plus its sanitized plain text (nil until hydrated).
    public func message(
        id: String, account: String
    ) async throws -> (row: MessageRow, plainText: String?)? {
        try await writer.read { db in
            guard let raw = try Row.fetchOne(
                db,
                sql: "SELECT * FROM messages WHERE account_email = ? AND id = ?",
                arguments: [account, id]) else { return nil }
            let row = try Self.messageRow(from: raw, account: account, db: db)
            let text = try String.fetchOne(
                db,
                sql: "SELECT plain_text FROM message_bodies WHERE account_email = ? AND message_id = ?",
                arguments: [account, id])
            return (row, text)
        }
    }

    static func messageRow(from raw: Row, account: String, db: Database) throws -> MessageRow {
        let id: String = raw["id"]
        let labels = try String.fetchAll(
            db,
            sql: "SELECT label_id FROM message_labels WHERE account_email = ? AND message_id = ? ORDER BY label_id",
            arguments: [account, id])
        return MessageRow(
            id: id, threadID: raw["thread_id"], historyID: raw["history_id"],
            internalDate: raw["internal_date"], fromLine: raw["from_line"],
            toLine: raw["to_line"], subject: raw["subject"], snippet: raw["snippet"],
            hasBody: raw["has_body"], labelIDs: labels)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StoreTests`
Expected: all Store tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(store): version-guarded snapshot writes, tombstones, ordered history application"
```

---

### Task 5: Accounts in the database + accounts.json migration

_(M1 obligation: AccountsFile→GRDB migration handling the existing non-ISO8601 `consentedAt` encoding.)_

**Files:**
- Create: `Sources/Store/AccountStore.swift`
- Create: `Sources/HudsonCLI/AccountsMigration.swift`
- Modify: `Sources/HudsonCLI/AccountsFile.swift` (mark legacy; used only by the migration)
- Modify: `Sources/HudsonCLI/AuthCommand.swift` (persist to the database instead of accounts.json)
- Modify: `Sources/HudsonCLI/ProfileCommand.swift` (read from the database)
- Test: `Tests/StoreTests/AccountStoreTests.swift`

**Interfaces:**
- Consumes: `HudsonDatabase` (Task 3).
- Produces:
  - `public struct AccountRecord: Sendable, Equatable` — `email, clientID: String`, `consentedAt: Date`, `historyCursor: Int64?`, `backfillState: String` (`"pending" | "listing" | "complete"`), `backfillPageToken: String?`, `backfilledCount: Int`
  - On `HudsonDatabase`: `func upsertAccount(email: String, clientID: String, consentedAt: Date) async throws`, `func account(email: String) async throws -> AccountRecord?`, `func primaryAccount() async throws -> AccountRecord?` (first by email), `func updateBackfill(email: String, state: String, pageToken: String?, addedCount: Int) async throws`
  - `enum AccountsMigration { static func runIfNeeded(database: HudsonDatabase) async throws }` — imports `accounts.json` (decoded with `JSONDecoder()` **default** date strategy, because that is what M1 wrote: seconds since reference date) into `accounts`, then renames the file to `accounts.json.migrated`. Idempotent: skips when the file is absent or the table already has rows.
  - `HudsonPaths.databaseURL` = `~/Library/Application Support/Hudson/hudson.sqlite` (small enum in `AccountsMigration.swift`).

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/AccountStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Store

@Test func accountRoundTrips() async throws {
    let database = try HudsonDatabase.inMemory()
    let consented = Date(timeIntervalSinceReferenceDate: 776_000_000)
    try await database.upsertAccount(email: "a@b.c", clientID: "cid", consentedAt: consented)
    let record = try #require(try await database.account(email: "a@b.c"))
    #expect(record.clientID == "cid")
    #expect(abs(record.consentedAt.timeIntervalSince(consented)) < 0.001)
    #expect(record.backfillState == "pending")
}

@Test func backfillProgressPersists() async throws {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "a@b.c", clientID: "cid", consentedAt: .now)
    try await database.updateBackfill(
        email: "a@b.c", state: "listing", pageToken: "page-2", addedCount: 150)
    let record = try #require(try await database.account(email: "a@b.c"))
    #expect(record.backfillState == "listing")
    #expect(record.backfillPageToken == "page-2")
    #expect(record.backfilledCount == 150)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountStoreTests`
Expected: FAIL — methods not defined.

- [ ] **Step 3: Implement AccountStore**

`Sources/Store/AccountStore.swift`:

```swift
import Foundation
import GRDB

/// One connected Gmail account as stored in SQLite (replaces M1's accounts.json).
public struct AccountRecord: Sendable, Equatable {
    public let email: String
    public let clientID: String
    public let consentedAt: Date
    public let historyCursor: Int64?
    public let backfillState: String
    public let backfillPageToken: String?
    public let backfilledCount: Int
}

extension HudsonDatabase {
    /// Inserts or updates an account. `consented_at` stores seconds since the
    /// reference date — the same encoding M1's accounts.json used, so migrated
    /// and fresh values are directly comparable.
    public func upsertAccount(email: String, clientID: String, consentedAt: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (email, client_id, consented_at) VALUES (?, ?, ?)
                    ON CONFLICT(email) DO UPDATE SET
                        client_id = excluded.client_id, consented_at = excluded.consented_at
                    """,
                arguments: [email, clientID, consentedAt.timeIntervalSinceReferenceDate])
        }
    }

    /// The stored record for one account, or nil if never connected.
    public func account(email: String) async throws -> AccountRecord? {
        try await writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM accounts WHERE email = ?", arguments: [email]
            ).map(Self.accountRecord(from:))
        }
    }

    /// The account CLI commands operate on (first alphabetically; M1 parity).
    public func primaryAccount() async throws -> AccountRecord? {
        try await writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM accounts ORDER BY email LIMIT 1"
            ).map(Self.accountRecord(from:))
        }
    }

    /// Persists backfill progress so a killed sync resumes where it stopped.
    public func updateBackfill(
        email: String, state: String, pageToken: String?, addedCount: Int
    ) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts SET backfill_state = ?, backfill_page_token = ?,
                        backfilled_count = backfilled_count + ? WHERE email = ?
                    """,
                arguments: [state, pageToken, addedCount, email])
        }
    }

    static func accountRecord(from row: Row) -> AccountRecord {
        AccountRecord(
            email: row["email"], clientID: row["client_id"],
            consentedAt: Date(timeIntervalSinceReferenceDate: row["consented_at"]),
            historyCursor: row["history_cursor"], backfillState: row["backfill_state"],
            backfillPageToken: row["backfill_page_token"],
            backfilledCount: row["backfilled_count"])
    }
}
```

- [ ] **Step 4: Implement the CLI migration and rewire the commands**

`Sources/HudsonCLI/AccountsMigration.swift`:

```swift
import Foundation
import Store

/// Filesystem locations the CLI uses.
enum HudsonPaths {
    /// The SQLite store: ~/Library/Application Support/Hudson/hudson.sqlite
    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hudson/hudson.sqlite")
    }
}

/// One-time import of M1's accounts.json into the database. M1 wrote dates
/// with JSONEncoder's DEFAULT strategy (seconds since the reference date, a
/// bare Double) — decode with the default strategy, never .iso8601.
enum AccountsMigration {
    static func runIfNeeded(database: HudsonDatabase) async throws {
        let legacyURL = AccountsFile.url
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard try await database.primaryAccount() == nil else { return }

        let legacy = try AccountsFile.load()
        for account in legacy {
            try await database.upsertAccount(
                email: account.email, clientID: account.clientID,
                consentedAt: account.consentedAt)
        }
        try FileManager.default.moveItem(
            at: legacyURL,
            to: legacyURL.deletingLastPathComponent().appending(path: "accounts.json.migrated"))
    }
}
```

In `AccountsFile.swift`, change the type doc comment's first line to:
`/// LEGACY (M1): superseded by the accounts table; kept only so AccountsMigration can read old installs. Do not add new callers.`

In `AuthCommand.swift`, replace the accounts.json persistence block at the end of `connect` with:

```swift
        let database = try HudsonDatabase.open(at: HudsonPaths.databaseURL)
        try await AccountsMigration.runIfNeeded(database: database)
        try await database.upsertAccount(
            email: profile.emailAddress, clientID: clientID, consentedAt: Date())
```

(add `import Store`). In `ProfileCommand.swift`, replace `AccountsFile.primary()` with:

```swift
        let database = try HudsonDatabase.open(at: HudsonPaths.databaseURL)
        try await AccountsMigration.runIfNeeded(database: database)
        guard let account = try await database.primaryAccount() else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
```

(`account.email` / `account.clientID` / `account.consentedAt` replace the old struct's fields; add `import Store`.)

- [ ] **Step 5: Run the full suite + manual migration check**

Run: `swift test` — all pass.
Run: `swift build && .build/debug/hudson profile` — on this machine an M1 `accounts.json` exists, so this run must (a) print the same live profile as before, and (b) leave `accounts.json.migrated` where `accounts.json` was. Verify both; record the output in the task notes.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(store,cli): accounts live in GRDB; one-time accounts.json migration"
```

---

### Task 6: HudsonCLI test target + shared invalid_grant predicate

_(M1 obligation: the Testing-status diagnostic depends on an undocumented substring contract; give it a shared predicate and real tests.)_

**Files:**
- Modify: `Package.swift` (add `HudsonCLITests` target; `HudsonCLI` needs `.testable` visibility — test target depends on `"HudsonCLI"`)
- Modify: `Sources/GmailKit/Transport/GmailError.swift` (add `indicatesInvalidGrant`)
- Modify: `Sources/HudsonCLI/ProfileCommand.swift` (`annotated` uses the predicate; make it `static func annotated(_:consentedAt:now:)` for testability)
- Test: `Tests/GmailKitTests/GmailErrorTests.swift` (predicate cases)
- Test: `Tests/HudsonCLITests/TestingStatusDiagnosticTests.swift`

**Interfaces:**
- Consumes: `GmailError`, `ProfileCommand`.
- Produces:
  - `GmailError.indicatesInvalidGrant: Bool` — true only for `.auth` whose message begins with `"invalid_grant"` (the exact prefix `OAuthClient.requestTokens` produces). Doc comment cross-references both call sites.
  - `ProfileCommand.annotated(_ error: GmailError, consentedAt: Date, now: Date = Date()) -> GmailError` — static, pure, testable.

- [ ] **Step 1: Add the test target**

In `Package.swift`, add:

```swift
        .testTarget(name: "HudsonCLITests", dependencies: ["HudsonCLI"]),
```

(The `HudsonCLI` executable target is testable via `@testable import HudsonCLI` — SwiftPM supports testing executable targets on macOS 15 toolchains; if the linker objects to the `@main` entry point, move `HudsonCommand` conformance unchanged into the same file but guard nothing — it links fine with Swift 6 toolchains.)

- [ ] **Step 2: Write the failing tests**

Append to `Tests/GmailKitTests/GmailErrorTests.swift`:

```swift
@Test func invalidGrantPredicateMatchesOAuthClientPhrasing() {
    #expect(GmailError.auth("invalid_grant: Token has been expired or revoked.").indicatesInvalidGrant)
    #expect(!GmailError.auth("No stored tokens — run `hudson auth` first.").indicatesInvalidGrant)
    #expect(!GmailError.rateLimited(retryAfter: nil).indicatesInvalidGrant)
}
```

`Tests/HudsonCLITests/TestingStatusDiagnosticTests.swift`:

```swift
import Foundation
import GmailKit
import Testing
@testable import HudsonCLI

private let invalidGrant = GmailError.auth("invalid_grant: Token has been expired or revoked.")

@Test func recentConsentGetsTestingStatusHint() {
    let consented = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 3 * 24 * 3600)  // 3 days later
    guard case .auth(let message) = ProfileCommand.annotated(
        invalidGrant, consentedAt: consented, now: now) else {
        Issue.record("expected .auth"); return
    }
    #expect(message.contains("PUBLISH APP"))
}

@Test func oldConsentPassesErrorThroughUnchanged() {
    let consented = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 30 * 24 * 3600)  // 30 days later
    #expect(ProfileCommand.annotated(invalidGrant, consentedAt: consented, now: now) == invalidGrant)
}

@Test func nonGrantErrorsAreNeverAnnotated() {
    let other = GmailError.auth("Keychain has no client secret — run `hudson auth` again.")
    let consented = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 3600)
    #expect(ProfileCommand.annotated(other, consentedAt: consented, now: now) == other)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter TestingStatusDiagnosticTests`
Expected: FAIL — `annotated` is instance-scoped/private and the predicate doesn't exist.

- [ ] **Step 4: Implement**

In `GmailError.swift`:

```swift
    /// True when this error means Google revoked or expired the OAuth grant.
    /// Contract: `OAuthClient.requestTokens` formats token-endpoint failures
    /// as "\(error): \(description)", so invalid_grant is always the message
    /// PREFIX. `ProfileCommand.annotated` builds its Testing-status hint on
    /// this predicate — if you change the phrasing there, this must move with it.
    public var indicatesInvalidGrant: Bool {
        if case .auth(let message) = self { return message.hasPrefix("invalid_grant") }
        return false
    }
```

In `ProfileCommand.swift`, make the helper static/pure and switch to the predicate:

```swift
    /// The spec-§6.1 heuristic: a dead grant within ~8 days of consent usually
    /// means the OAuth app was left in “Testing” status. Pure for testability.
    static func annotated(
        _ error: GmailError, consentedAt: Date, now: Date = Date()
    ) -> GmailError {
        guard error.indicatesInvalidGrant, case .auth(let message) = error,
              now.timeIntervalSince(consentedAt) < 8 * 24 * 3600 else {
            return error
        }
        return .auth(message + """


        Your grant died within a week of setup — the OAuth app is probably still in
        “Testing” status, where refresh tokens expire every 7 days. Fix: Google Auth
        Platform → Audience → Publishing status → PUBLISH APP, then `hudson auth`.
        """)
    }
```

Update its call site to `Self.annotated(error, consentedAt: account.consentedAt)`.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all pass, including the three new CLI tests.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "test(cli): HudsonCLI test target; shared invalid_grant predicate for the Testing-status hint"
```

---

### Task 7: Sanitizer pipeline (Store)

**Files:**
- Create: `Sources/Store/Sanitizer.swift`
- Create: `Sources/Store/StoreBodies.swift`
- Test: `Tests/StoreTests/SanitizerTests.swift`

**Interfaces:**
- Consumes: `HudsonDatabase` (Task 3), `messages.has_body` column (Task 3).
- Produces:
  - `public struct SanitizedBody: Sendable, Equatable` — `rawHTML: Data?`, `plainText: String`, `sanitizerVersion: Int`, `cidReferences: [String]`, `remoteURLs: [String]`
  - `public enum Sanitizer` — `static let version = 1`; `static func sanitize(html: Data?, plainText: String?) -> SanitizedBody` (prefers the plain part; derives text from HTML via tag-stripping otherwise; collects `cid:` references and `http(s)://` resource URLs from the HTML); `static func terminalSafe(_ string: String) -> String` (strips C0/C1 controls except `\n`/`\t`, and ANSI CSI/OSC sequences)
  - On `HudsonDatabase`: `func saveBody(messageID: String, account: String, body: SanitizedBody) async throws` (upserts `message_bodies`, sets `messages.has_body = true`, one transaction); `func messageIDsNeedingBodies(account: String, since: Int64, limit: Int) async throws -> [String]` (hydration work-list: `has_body = false AND internal_date >= since`, newest first).

- [ ] **Step 1: Write the failing tests**

`Tests/StoreTests/SanitizerTests.swift`:

```swift
import Foundation
import Testing
@testable import Store

@Test func prefersProvidedPlainTextOverHTML() {
    let body = Sanitizer.sanitize(html: Data("<p>html</p>".utf8), plainText: "the plain part")
    #expect(body.plainText == "the plain part")
    #expect(body.rawHTML == Data("<p>html</p>".utf8))
    #expect(body.sanitizerVersion == Sanitizer.version)
}

@Test func derivesTextFromHTMLWhenNoPlainPart() {
    let html = "<div>Hello<br>world &amp; <b>friends</b><script>evil()</script></div>"
    let body = Sanitizer.sanitize(html: Data(html.utf8), plainText: nil)
    #expect(body.plainText.contains("Hello"))
    #expect(body.plainText.contains("world & friends"))
    #expect(!body.plainText.contains("evil"))       // script content dropped
    #expect(!body.plainText.contains("<"))          // no tags survive
}

@Test func collectsCidAndRemoteReferences() {
    let html = #"<img src="cid:logo@x"><img src="https://t.example/px.gif"><a href="http://a.example/y">l</a>"#
    let body = Sanitizer.sanitize(html: Data(html.utf8), plainText: "t")
    #expect(body.cidReferences == ["logo@x"])
    #expect(body.remoteURLs.contains("https://t.example/px.gif"))
    #expect(body.remoteURLs.contains("http://a.example/y"))
}

@Test func terminalSafeStripsEscapesAndControls() {
    let hostile = "subject\u{1B}[31mred\u{1B}]0;title\u{07}\u{0007}bell\u{9B}csi\nok\ttab"
    let safe = Sanitizer.terminalSafe(hostile)
    #expect(!safe.contains("\u{1B}"))
    #expect(!safe.contains("\u{9B}"))
    #expect(!safe.contains("\u{07}"))
    #expect(safe.contains("\nok\ttab"))  // newline and tab survive
    #expect(safe.contains("subject"))
}

@Test func saveBodyMarksMessageHydrated() async throws {
    let database = try HudsonDatabase.inMemory()
    let snapshot = MessageSnapshot(
        id: "m1", threadID: "t1", historyID: 1, internalDate: 99,
        fromLine: "f", toLine: "t", subject: "s", snippet: "sn", labelIDs: [])
    _ = try await database.applySnapshot(snapshot, account: "x")
    try await database.saveBody(
        messageID: "m1", account: "x",
        body: Sanitizer.sanitize(html: nil, plainText: "hello"))
    let fetched = try #require(try await database.message(id: "m1", account: "x"))
    #expect(fetched.row.hasBody)
    #expect(fetched.plainText == "hello")
    #expect(try await database.messageIDsNeedingBodies(account: "x", since: 0, limit: 10).isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SanitizerTests`
Expected: FAIL — `Sanitizer` not defined.

- [ ] **Step 3: Implement**

`Sources/Store/Sanitizer.swift`:

```swift
import Foundation

/// Derived, display-safe content for one message body (spec §3.5). The raw
/// HTML is carried as opaque bytes for the future renderer; everything the
/// terminal or FTS ever sees comes from `plainText`.
public struct SanitizedBody: Sendable, Equatable {
    public let rawHTML: Data?
    public let plainText: String
    public let sanitizerVersion: Int
    public let cidReferences: [String]
    public let remoteURLs: [String]
}

/// The single sanitizer/extractor (spec §3.5). Mail content is hostile input:
/// nothing from a message reaches the terminal or the index except through
/// this type. Bump `version` on behavior change so stored bodies re-derive.
public enum Sanitizer {
    public static let version = 1

    /// Builds the derived body. Prefers the sender's text/plain part; falls
    /// back to stripping the HTML. Also inventories cid: and remote references
    /// so the future WKWebView renderer can block remote loads (spec §3.5).
    public static func sanitize(html: Data?, plainText: String?) -> SanitizedBody {
        let htmlString = html.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let text: String
        if let plainText, !plainText.isEmpty {
            text = plainText
        } else {
            text = strippedText(fromHTML: htmlString)
        }
        return SanitizedBody(
            rawHTML: html,
            plainText: text,
            sanitizerVersion: version,
            cidReferences: matches(#"src="cid:([^"]+)""#, in: htmlString),
            remoteURLs: matches(#"(?:src|href)="(https?://[^"]+)""#, in: htmlString))
    }

    /// Strips C0/C1 control characters (keeping \n and \t) and ANSI CSI/OSC
    /// escape sequences. Every message-derived string printed to a terminal
    /// goes through this — escape injection is reachable from `hudson list`.
    public static func terminalSafe(_ string: String) -> String {
        // Drop CSI/OSC sequences first (ESC or 0x9B introducer), then any
        // remaining control scalars.
        var cleaned = string
        for pattern in [
            #"(?:\x1B\[|\x{9B})[0-?]*[ -/]*[@-~]"#,     // CSI … final byte
            #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?"#,     // OSC … BEL/ST
            #"\x1B."#,                                   // any other escape pair
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return String(cleaned.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
        })
    }

    // MARK: - HTML text extraction (M2: tag stripper; real rendering is WKWebView later)

    static func strippedText(fromHTML html: String) -> String {
        var text = html
        // Drop script/style bodies entirely, then all tags, then decode the
        // entities that matter for readability.
        for pattern in [#"(?is)<(script|style)\b.*?</\1>"#, #"(?s)<br\s*/?>"#] {
            text = text.replacingOccurrences(
                of: pattern, with: pattern.contains("br") ? "\n" : " ",
                options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, plain) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
        ] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        return text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ pattern: String, in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            Range(match.range(at: 1), in: string).map { String(string[$0]) }
        }
    }
}
```

`Sources/Store/StoreBodies.swift`:

```swift
import Foundation
import GRDB

extension HudsonDatabase {
    /// Stores a sanitized body and flags the message hydrated — one transaction.
    public func saveBody(messageID: String, account: String, body: SanitizedBody) async throws {
        let cids = String(decoding: try JSONEncoder().encode(body.cidReferences), as: UTF8.self)
        let urls = String(decoding: try JSONEncoder().encode(body.remoteURLs), as: UTF8.self)
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message_bodies
                        (account_email, message_id, raw_html, plain_text,
                         sanitizer_version, cid_references, remote_urls)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_email, message_id) DO UPDATE SET
                        raw_html = excluded.raw_html, plain_text = excluded.plain_text,
                        sanitizer_version = excluded.sanitizer_version,
                        cid_references = excluded.cid_references,
                        remote_urls = excluded.remote_urls
                    """,
                arguments: [
                    account, messageID, body.rawHTML, body.plainText,
                    body.sanitizerVersion, cids, urls,
                ])
            try db.execute(
                sql: "UPDATE messages SET has_body = 1 WHERE account_email = ? AND id = ?",
                arguments: [account, messageID])
        }
    }

    /// The hydration work-list: newest un-hydrated messages within the window.
    public func messageIDsNeedingBodies(
        account: String, since: Int64, limit: Int
    ) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM messages
                    WHERE account_email = ? AND has_body = 0 AND internal_date >= ?
                    ORDER BY internal_date DESC LIMIT ?
                    """,
                arguments: [account, since, limit])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SanitizerTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(store): sanitizer pipeline — derived text, cid/remote inventory, terminal safety"
```

---

### Task 8: GmailKit — list/get/history endpoints and content extraction

**Files:**
- Create: `Sources/GmailKit/API/Models/GmailMessage.swift`
- Create: `Sources/GmailKit/API/Models/HistoryPage.swift`
- Create: `Sources/GmailKit/API/MessageEndpoints.swift`
- Create: `Tests/GmailKitTests/Fixtures/message_full.json`
- Create: `Tests/GmailKitTests/Fixtures/history_page.json`
- Test: `Tests/GmailKitTests/MessageEndpointTests.swift`

**Interfaces:**
- Consumes: `GmailClient` request core (Task 1), `MockTransport`, quota costs.
- Produces (all `Decodable, Sendable`):
  - `MessageRef { id, threadId: String }`, `MessageListPage { messages: [MessageRef]?, nextPageToken: String?, resultSizeEstimate: Int? }`
  - `GmailMessage { id, threadId, historyId: String, internalDate: String?, labelIds: [String]?, snippet: String?, payload: MessagePart? }` with `MessagePart { mimeType: String?, filename: String?, headers: [MessageHeaderField]?, body: MessagePartBody?, parts: [MessagePart]? }`, `MessageHeaderField { name, value: String }`, `MessagePartBody { data: String?, size: Int? }`
  - `GmailMessage.header(_ name: String) -> String?` (case-insensitive, from payload headers)
  - `public struct ExtractedContent: Sendable { htmlData: Data?, plainText: String? }` and `GmailMessage.extractContent() -> ExtractedContent` — depth-first part walk: first `text/plain` part and first `text/html` part, base64url-decoded (`-`→`+`, `_`→`/`, re-padded)
  - `HistoryPage { history: [HistoryRecord]?, nextPageToken: String?, historyId: String? }`, `HistoryRecord { id: String, messagesAdded: [ChangedMessage]?, messagesDeleted: [ChangedMessage]?, labelsAdded: [LabelChange]?, labelsRemoved: [LabelChange]? }`, `ChangedMessage { message: GmailMessage }`, `LabelChange { message: GmailMessage }` (Gmail puts post-change `labelIds` on the nested message)
  - `GmailLabel { id, name: String }`, `LabelListResponse { labels: [GmailLabel]? }`
  - On `GmailClient`:
    - `func listMessages(pageToken: String?, maxResults: Int = 100) async throws -> MessageListPage` — template `users/me/messages`, cost `GmailQuotaCost.messagesList`
    - `func getMessage(id: String, format: String) async throws -> GmailMessage` — template `users/me/messages/{id}`, path `users/me/messages/\(id)`, query `format`, cost `messagesGet`
    - `func listHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage` — template `users/me/history`, cost `historyList` (a 404 here surfaces as `GmailError.invalidRequest(status: 404, …)` — SyncEngine treats that as history expiry)
    - `func listLabels() async throws -> [GmailLabel]` — template `users/me/labels`, cost `labelsList`

- [ ] **Step 1: Write the fixtures**

`Tests/GmailKitTests/Fixtures/message_full.json` (shape-faithful, fake content; `aGVsbG8gcGxhaW4=` is "hello plain", `PGI-aHRtbDwvYj4=` is base64url of `<b>html</b>`):

```json
{
  "id": "18f0a",
  "threadId": "18f00",
  "historyId": "4711",
  "internalDate": "1754820000000",
  "labelIds": ["INBOX", "UNREAD"],
  "snippet": "hello plain",
  "payload": {
    "mimeType": "multipart/alternative",
    "headers": [
      {"name": "From", "value": "Ada <ada@example.com>"},
      {"name": "To", "value": "you@example.com"},
      {"name": "Subject", "value": "Test message"}
    ],
    "parts": [
      {"mimeType": "text/plain", "body": {"data": "aGVsbG8gcGxhaW4", "size": 11}},
      {"mimeType": "text/html", "body": {"data": "PGI-aHRtbDwvYj4", "size": 11}}
    ]
  }
}
```

`Tests/GmailKitTests/Fixtures/history_page.json`:

```json
{
  "historyId": "4720",
  "history": [
    {
      "id": "4712",
      "messagesAdded": [{"message": {"id": "18f0b", "threadId": "18f00", "historyId": "4712", "labelIds": ["INBOX"]}}]
    },
    {
      "id": "4715",
      "labelsRemoved": [{"message": {"id": "18f0a", "threadId": "18f00", "historyId": "4715", "labelIds": ["INBOX"]}}]
    },
    {
      "id": "4718",
      "messagesDeleted": [{"message": {"id": "18f09", "threadId": "18ef0", "historyId": "4718"}}]
    }
  ]
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/GmailKitTests/MessageEndpointTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private func makeClient(transport: MockTransport) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture),
        account: "a@example.com")
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(
            credentials: OAuthCredentials(clientID: "id", clientSecret: "secret"),
            transport: transport),
        store: store)
    return GmailClient(session: session, transport: transport, quota: QuotaBucket())
}

@Test func getMessageDecodesAndExtractsBothParts() async throws {
    let transport = MockTransport(responses: [(try fixture("message_full"), 200)])
    let message = try await makeClient(transport: transport)
        .getMessage(id: "18f0a", format: "full")
    #expect(message.historyId == "4711")
    #expect(message.header("subject") == "Test message")
    #expect(message.header("FROM") == "Ada <ada@example.com>")
    let content = message.extractContent()
    #expect(content.plainText == "hello plain")
    #expect(content.htmlData.map { String(decoding: $0, as: UTF8.self) } == "<b>html</b>")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path() == "/gmail/v1/users/me/messages/18f0a")
    #expect(request.url?.query()?.contains("format=full") == true)
}

@Test func historyPageDecodesAllChangeKinds() async throws {
    let transport = MockTransport(responses: [(try fixture("history_page"), 200)])
    let page = try await makeClient(transport: transport)
        .listHistory(startHistoryID: "4711", pageToken: nil)
    let records = try #require(page.history)
    #expect(records.count == 3)
    #expect(records[0].messagesAdded?.first?.message.id == "18f0b")
    #expect(records[1].labelsRemoved?.first?.message.labelIds == ["INBOX"])
    #expect(records[2].messagesDeleted?.first?.message.id == "18f09")
    #expect(page.historyId == "4720")
}

@Test func listMessagesPassesPageToken() async throws {
    let body = #"{"messages": [{"id": "a", "threadId": "t"}], "nextPageToken": "tok2", "resultSizeEstimate": 12}"#
    let transport = MockTransport(responses: [(Data(body.utf8), 200)])
    let page = try await makeClient(transport: transport)
        .listMessages(pageToken: "tok1", maxResults: 50)
    #expect(page.messages?.first?.id == "a")
    #expect(page.nextPageToken == "tok2")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.query()?.contains("pageToken=tok1") == true)
    #expect(request.url?.query()?.contains("maxResults=50") == true)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter MessageEndpointTests`
Expected: FAIL — types not defined.

- [ ] **Step 4: Implement**

`Sources/GmailKit/API/Models/GmailMessage.swift`:

```swift
import Foundation

/// A message id/thread id pair from `messages.list`.
public struct MessageRef: Decodable, Sendable {
    public let id: String
    public let threadId: String
}

/// One page of `messages.list`.
public struct MessageListPage: Decodable, Sendable {
    public let messages: [MessageRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?
}

/// A header field inside a message payload.
public struct MessageHeaderField: Decodable, Sendable {
    public let name: String
    public let value: String
}

/// The body carried by a MIME part (base64url in `data`).
public struct MessagePartBody: Decodable, Sendable {
    public let data: String?
    public let size: Int?
}

/// One node of the MIME part tree.
public struct MessagePart: Decodable, Sendable {
    public let mimeType: String?
    public let filename: String?
    public let headers: [MessageHeaderField]?
    public let body: MessagePartBody?
    public let parts: [MessagePart]?
}

/// The Message resource. `historyId` is the §4.2 version guard's source.
public struct GmailMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
    public let historyId: String
    public let internalDate: String?
    public let labelIds: [String]?
    public let snippet: String?
    public let payload: MessagePart?

    /// Case-insensitive header lookup on the top-level payload.
    public func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The text and HTML alternatives found in a message's part tree.
public struct ExtractedContent: Sendable {
    public let htmlData: Data?
    public let plainText: String?
}

extension GmailMessage {
    /// Depth-first walk: first text/plain and first text/html leaves,
    /// base64url-decoded. Attachments are ignored in M2 (lazy download later).
    public func extractContent() -> ExtractedContent {
        var plain: Data?
        var html: Data?
        func walk(_ part: MessagePart?) {
            guard let part else { return }
            if part.mimeType == "text/plain", plain == nil {
                plain = part.body?.data.flatMap(Self.decodeBase64URL)
            }
            if part.mimeType == "text/html", html == nil {
                html = part.body?.data.flatMap(Self.decodeBase64URL)
            }
            for child in part.parts ?? [] { walk(child) }
        }
        walk(payload)
        return ExtractedContent(
            htmlData: html,
            plainText: plain.map { String(decoding: $0, as: UTF8.self) })
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

/// A Gmail label (id → display name).
public struct GmailLabel: Decodable, Sendable {
    public let id: String
    public let name: String
}

/// `labels.list` response envelope.
public struct LabelListResponse: Decodable, Sendable {
    public let labels: [GmailLabel]?
}
```

`Sources/GmailKit/API/Models/HistoryPage.swift`:

```swift
/// A message referenced by a history record (post-change state nested inside).
public struct ChangedMessage: Decodable, Sendable {
    public let message: GmailMessage
}

/// One history record; each array holds the changes of that kind.
public struct HistoryRecord: Decodable, Sendable {
    public let id: String
    public let messagesAdded: [ChangedMessage]?
    public let messagesDeleted: [ChangedMessage]?
    public let labelsAdded: [ChangedMessage]?
    public let labelsRemoved: [ChangedMessage]?
}

/// One page of `history.list`. `historyId` is the new cursor after this page.
public struct HistoryPage: Decodable, Sendable {
    public let history: [HistoryRecord]?
    public let nextPageToken: String?
    public let historyId: String?
}
```

`Sources/GmailKit/API/MessageEndpoints.swift`:

```swift
import Foundation

extension GmailClient {
    /// One newest-first page of message ids (spec §4.1 backfill driver).
    public func listMessages(
        pageToken: String?, maxResults: Int = 100
    ) async throws -> MessageListPage {
        var query = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get(
            template: "users/me/messages", path: "users/me/messages",
            query: query, cost: GmailQuotaCost.messagesList)
    }

    /// One message. `format` is "metadata" (headers only), "full", or "minimal".
    public func getMessage(id: String, format: String) async throws -> GmailMessage {
        try await get(
            template: "users/me/messages/{id}", path: "users/me/messages/\(id)",
            query: [URLQueryItem(name: "format", value: format)],
            cost: GmailQuotaCost.messagesGet)
    }

    /// Changes since `startHistoryID`. A 404 means the cursor expired —
    /// callers must fall back to reconciliation (spec §4.3).
    public func listHistory(
        startHistoryID: String, pageToken: String?
    ) async throws -> HistoryPage {
        var query = [URLQueryItem(name: "startHistoryId", value: startHistoryID)]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get(
            template: "users/me/history", path: "users/me/history",
            query: query, cost: GmailQuotaCost.historyList)
    }

    /// All labels (id → name) for display.
    public func listLabels() async throws -> [GmailLabel] {
        let response: LabelListResponse = try await get(
            template: "users/me/labels", path: "users/me/labels",
            cost: GmailQuotaCost.labelsList)
        return response.labels ?? []
    }
}
```

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): messages.list/get, history.list, labels.list + MIME content extraction"
```

---

### Task 9: SyncEngine — backfill

**Files:**
- Modify: `Package.swift` (new `SyncEngine` target: deps `GmailKit`, `Store`; new `SyncEngineTests`; add `"SyncEngine"` to `HudsonCLI` deps)
- Create: `Sources/SyncEngine/SyncEngine.swift`
- Create: `Sources/SyncEngine/SnapshotMapping.swift`
- Create: `Tests/SyncEngineTests/Support/ScriptedGmail.swift`
- Test: `Tests/SyncEngineTests/BackfillTests.swift`

**Interfaces:**
- Consumes: `GmailClient` endpoints (Task 8), `HudsonDatabase` writes (Tasks 4/5/7), `Sanitizer` (Task 7).
- Produces:
  - `public protocol GmailAPI: Sendable` — the SyncEngine-facing seam so tests don't need HTTP: `getProfile() -> Profile`, `listMessages(pageToken:maxResults:) -> MessageListPage`, `getMessage(id:format:) -> GmailMessage`, `listHistory(startHistoryID:pageToken:) -> HistoryPage`, `listLabels() -> [GmailLabel]` (exact signatures from Task 8). `extension GmailClient: GmailAPI {}`.
  - `public actor SyncEngine` — `init(api: any GmailAPI, database: HudsonDatabase, account: String, pageSize: Int = 100, hydrationBatch: Int = 25, prefetchWindowDays: Int = 90, now: @escaping @Sendable () -> Date = { Date() })`
  - `public struct SyncReport: Sendable, Equatable { public var backfilledThisPass: Int; public var eventsApplied: Int; public var bodiesHydrated: Int; public var backfillComplete: Bool }`
  - `func syncOnce(maxBackfillPages: Int = 5) async throws -> SyncReport` — single-flight (a second concurrent call returns an empty report immediately); order: ensure cursor → poll history (Task 10 fills this in; this task leaves a stub returning 0 events) → backfill up to N pages → hydrate one batch.
  - `SnapshotMapping.snapshot(from message: GmailMessage) -> MessageSnapshot?` (nil when historyId/internalDate unparsable; `From`/`To`/`Subject` from headers, empty-string fallbacks).
  - `ScriptedGmail`: actor implementing `GmailAPI` over scripted pages/messages (test double for this and all later sync tests).

- [ ] **Step 1: Write the test double**

`Tests/SyncEngineTests/Support/ScriptedGmail.swift`:

```swift
import GmailKit
@testable import SyncEngine

/// Scriptable in-memory Gmail for SyncEngine tests: serves canned list pages,
/// messages, and history pages; records every call.
actor ScriptedGmail: GmailAPI {
    var profile: Profile
    var listPages: [MessageListPage]
    var messagesByID: [String: GmailMessage]
    var historyPages: [HistoryPage]
    /// When set, listHistory throws this (e.g. 404 expiry) instead of serving.
    var historyError: GmailError?
    private(set) var calls: [String] = []

    init(
        profile: Profile = Profile(
            emailAddress: "x", messagesTotal: 0, threadsTotal: 0, historyId: "100"),
        listPages: [MessageListPage] = [],
        messagesByID: [String: GmailMessage] = [:],
        historyPages: [HistoryPage] = []
    ) {
        self.profile = profile
        self.listPages = listPages
        self.messagesByID = messagesByID
        self.historyPages = historyPages
    }

    func getProfile() async throws -> Profile {
        calls.append("profile")
        return profile
    }

    func listMessages(pageToken: String?, maxResults: Int) async throws -> MessageListPage {
        calls.append("list:\(pageToken ?? "start")")
        guard !listPages.isEmpty else {
            return MessageListPage(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
        }
        return listPages.removeFirst()
    }

    func getMessage(id: String, format: String) async throws -> GmailMessage {
        calls.append("get:\(id):\(format)")
        guard let message = messagesByID[id] else {
            throw GmailError.invalidRequest(status: 404, message: "no message \(id)")
        }
        return message
    }

    func listHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        calls.append("history:\(startHistoryID)")
        if let historyError { throw historyError }
        guard !historyPages.isEmpty else {
            return HistoryPage(history: nil, nextPageToken: nil, historyId: startHistoryID)
        }
        return historyPages.removeFirst()
    }

    func listLabels() async throws -> [GmailLabel] {
        calls.append("labels")
        return []
    }

    func setHistoryError(_ error: GmailError?) { historyError = error }
}

/// Builds a metadata-format GmailMessage for tests.
func testMessage(
    id: String, threadID: String = "t1", historyID: String, internalDate: String = "1000",
    labels: [String] = ["INBOX"], subject: String = "s"
) -> GmailMessage {
    // Decodable structs: round-trip through JSON to construct.
    let json = """
        {"id": "\(id)", "threadId": "\(threadID)", "historyId": "\(historyID)",
         "internalDate": "\(internalDate)", "labelIds": \(labels.map { "\"\($0)\"" }),
         "snippet": "sn",
         "payload": {"headers": [
            {"name": "From", "value": "a@ex.com"}, {"name": "To", "value": "b@ex.com"},
            {"name": "Subject", "value": "\(subject)"}]}}
        """
    return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
}
```

*(If `MessageListPage`/`HistoryPage` need memberwise inits for the double, add `public init(...)` with doc comments to those structs in GmailKit — Decodable structs accept explicit inits without affecting decoding.)*

- [ ] **Step 2: Write the failing tests**

`Tests/SyncEngineTests/BackfillTests.swift`:

```swift
import GmailKit
import Store
import Testing
@testable import SyncEngine

private func makeWorld(
    pages: [MessageListPage], messages: [String: GmailMessage]
) async throws -> (ScriptedGmail, HudsonDatabase, SyncEngine) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail(listPages: pages, messagesByID: messages)
    let engine = SyncEngine(api: gmail, database: database, account: "x")
    return (gmail, database, engine)
}

@Test func backfillRecordsCursorBeforeListing() async throws {
    let (gmail, database, engine) = try await makeWorld(pages: [], messages: [:])
    _ = try await engine.syncOnce()
    // Cursor must be recorded from profile BEFORE any list call (spec §4.1).
    let calls = await gmail.calls
    #expect(calls.first == "profile")
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 100)
    #expect(account.backfillState == "complete")  // empty mailbox completes at once
}

@Test func backfillPersistsMessagesAndResumesFromPageToken() async throws {
    let page1 = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1"), MessageRef(id: "m2", threadId: "t1")],
        nextPageToken: "p2", resultSizeEstimate: 3)
    let page2 = MessageListPage(
        messages: [MessageRef(id: "m3", threadId: "t2")], nextPageToken: nil,
        resultSizeEstimate: 3)
    let messages = [
        "m1": testMessage(id: "m1", historyID: "90"),
        "m2": testMessage(id: "m2", historyID: "91"),
        "m3": testMessage(id: "m3", threadID: "t2", historyID: "92"),
    ]
    let (_, database, engine) = try await makeWorld(pages: [page1, page2], messages: messages)

    // Limit to one page per pass: state must persist between passes.
    let first = try await engine.syncOnce(maxBackfillPages: 1)
    #expect(first.backfilledThisPass == 2)
    #expect(!first.backfillComplete)
    var account = try #require(try await database.primaryAccount())
    #expect(account.backfillPageToken == "p2")
    #expect(account.backfillState == "listing")

    let second = try await engine.syncOnce(maxBackfillPages: 1)
    #expect(second.backfilledThisPass == 1)
    #expect(second.backfillComplete)
    account = try #require(try await database.primaryAccount())
    #expect(account.backfillState == "complete")
    #expect(try await database.recentMessages(account: "x", limit: 10).count == 3)
}

@Test func concurrentSyncOnceIsSingleFlight() async throws {
    let page = MessageListPage(
        messages: [MessageRef(id: "m1", threadId: "t1")], nextPageToken: nil,
        resultSizeEstimate: 1)
    let (_, _, engine) = try await makeWorld(
        pages: [page], messages: ["m1": testMessage(id: "m1", historyID: "90")])
    async let a = engine.syncOnce()
    async let b = engine.syncOnce()
    let (ra, rb) = try await (a, b)
    // Exactly one pass did work; the other returned the empty coalesced report.
    #expect([ra.backfilledThisPass, rb.backfilledThisPass].sorted() == [0, 1])
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter BackfillTests`
Expected: FAIL — `SyncEngine`/`GmailAPI` not defined.

- [ ] **Step 4: Implement**

`Sources/SyncEngine/SnapshotMapping.swift`:

```swift
import GmailKit
import Store

/// Maps Gmail DTOs to Store snapshots. The only place the two vocabularies meet.
enum SnapshotMapping {
    /// nil when the message lacks a parsable historyId (never observed in
    /// practice; guarding beats crashing on hostile data).
    static func snapshot(from message: GmailMessage) -> MessageSnapshot? {
        guard let historyID = Int64(message.historyId) else { return nil }
        return MessageSnapshot(
            id: message.id,
            threadID: message.threadId,
            historyID: historyID,
            internalDate: message.internalDate.flatMap(Int64.init) ?? 0,
            fromLine: message.header("From") ?? "",
            toLine: message.header("To") ?? "",
            subject: message.header("Subject") ?? "",
            snippet: message.snippet ?? "",
            labelIDs: message.labelIds ?? [])
    }
}
```

`Sources/SyncEngine/SyncEngine.swift`:

```swift
import Foundation
import GmailKit
import Store

/// The slice of GmailClient SyncEngine needs — a seam so tests script the
/// server instead of mocking HTTP.
public protocol GmailAPI: Sendable {
    func getProfile() async throws -> Profile
    func listMessages(pageToken: String?, maxResults: Int) async throws -> MessageListPage
    func getMessage(id: String, format: String) async throws -> GmailMessage
    func listHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage
    func listLabels() async throws -> [GmailLabel]
}

extension GmailClient: GmailAPI {}

/// What one sync pass accomplished.
public struct SyncReport: Sendable, Equatable {
    public var backfilledThisPass = 0
    public var eventsApplied = 0
    public var bodiesHydrated = 0
    public var backfillComplete = false

    /// Empty report — also what a coalesced (second concurrent) pass returns.
    public init() {}
}

/// Orchestrates backfill, history polling, and body hydration for one account
/// (spec §4). Single-flight: one pass in flight; concurrent calls coalesce to
/// an empty report (§4.6). All cross-pass state lives in SQLite.
public actor SyncEngine {
    private let api: any GmailAPI
    private let database: HudsonDatabase
    private let account: String
    private let pageSize: Int
    private let hydrationBatch: Int
    private let prefetchWindowDays: Int
    private let now: @Sendable () -> Date
    private var passInFlight = false

    /// Wires the engine to one account's API client and store.
    public init(
        api: any GmailAPI, database: HudsonDatabase, account: String,
        pageSize: Int = 100, hydrationBatch: Int = 25, prefetchWindowDays: Int = 90,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.database = database
        self.account = account
        self.pageSize = pageSize
        self.hydrationBatch = hydrationBatch
        self.prefetchWindowDays = prefetchWindowDays
        self.now = now
    }

    /// One bounded pass: ensure cursor → apply history → up to
    /// `maxBackfillPages` backfill pages → one hydration batch.
    public func syncOnce(maxBackfillPages: Int = 5) async throws -> SyncReport {
        guard !passInFlight else { return SyncReport() }
        passInFlight = true
        defer { passInFlight = false }

        var report = SyncReport()
        try await ensureCursor()
        report.eventsApplied = try await pollHistory()
        try await backfill(maxPages: maxBackfillPages, into: &report)
        report.bodiesHydrated = try await hydrateBodies()
        return report
    }

    // MARK: - Cursor

    /// Records profile.historyId BEFORE the first list call (spec §4.1), so
    /// incremental sync covers everything that changes mid-backfill.
    private func ensureCursor() async throws {
        guard let record = try await database.account(email: account) else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        guard record.historyCursor == nil else { return }
        let profile = try await api.getProfile()
        try await database.applyHistory(
            [], newCursor: Int64(profile.historyId) ?? 0, account: account)
    }

    // MARK: - History (M2: applied via Store; expiry fallback restarts backfill)

    /// Polls history.list and applies changes in order. Returns events applied.
    /// Task 10 extends this; the Task 9 skeleton returns 0 without polling.
    private func pollHistory() async throws -> Int { 0 }

    // MARK: - Backfill

    private func backfill(maxPages: Int, into report: inout SyncReport) async throws {
        var record = try await requireAccount()
        if record.backfillState == "complete" {
            report.backfillComplete = true
            return
        }
        for _ in 0..<maxPages {
            let page = try await api.listMessages(
                pageToken: record.backfillPageToken, maxResults: pageSize)
            var added = 0
            for ref in page.messages ?? [] {
                let message = try await api.getMessage(id: ref.id, format: "metadata")
                guard let snapshot = SnapshotMapping.snapshot(from: message) else { continue }
                if try await database.applySnapshot(snapshot, account: account) == .applied {
                    added += 1
                }
            }
            report.backfilledThisPass += added
            let finished = page.nextPageToken == nil
            try await database.updateBackfill(
                email: account,
                state: finished ? "complete" : "listing",
                pageToken: page.nextPageToken,
                addedCount: added)
            if finished {
                report.backfillComplete = true
                return
            }
            record = try await requireAccount()
        }
    }

    // MARK: - Body hydration (newest-first within the prefetch window)

    private func hydrateBodies() async throws -> Int {
        let windowStart = Int64(
            now().addingTimeInterval(-Double(prefetchWindowDays) * 86_400)
                .timeIntervalSince1970 * 1_000)
        let ids = try await database.messageIDsNeedingBodies(
            account: account, since: windowStart, limit: hydrationBatch)
        var hydrated = 0
        for id in ids {
            let message = try await api.getMessage(id: id, format: "full")
            let content = message.extractContent()
            try await database.saveBody(
                messageID: id, account: account,
                body: Sanitizer.sanitize(html: content.htmlData, plainText: content.plainText))
            hydrated += 1
        }
        return hydrated
    }

    private func requireAccount() async throws -> AccountRecord {
        guard let record = try await database.account(email: account) else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        return record
    }
}
```

Update `Package.swift` targets:

```swift
        .target(name: "SyncEngine", dependencies: ["GmailKit", "Store"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"]),
```

and add `"SyncEngine"` to `HudsonCLI`'s dependency list.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(sync): resumable quota-paced backfill with cursor-first ordering and body hydration"
```

---

### Task 10: SyncEngine — history polling, in-order application, expiry fallback

**Files:**
- Modify: `Sources/SyncEngine/SyncEngine.swift` (implement `pollHistory`)
- Create: `Sources/SyncEngine/HistoryMapping.swift`
- Test: `Tests/SyncEngineTests/HistoryTests.swift`

**Interfaces:**
- Consumes: everything from Task 9; `HudsonDatabase.applyHistory` (Task 4).
- Produces:
  - `HistoryMapping.changes(from records: [HistoryRecord]) -> [HistoryChange]` — flattens records in order: `messagesAdded` → `.added(snapshot)`; `messagesDeleted` → `.deleted(id)`; `labelsAdded`/`labelsRemoved` → `.labels(id:historyID:labelIDs:)` using the record's `id` as the version and the nested message's post-change `labelIds`.
  - `pollHistory()` real behavior: no cursor → 0; pages of `listHistory` applied via `database.applyHistory` (page's changes + that page's `historyId` cursor, one transaction per page); unknown ids returned by the Store are hydrated (`format: "metadata"` → `applySnapshot`); **404 (`GmailError.invalidRequest(status: 404, …)`) → expiry fallback:** reset backfill (`state: "pending"`, `pageToken: nil`), fetch a fresh profile cursor, log one warning line, return 0 — the re-list then reconverges the store (M3 replaces this blunt fallback with the `format=minimal` reconciliation of §4.3).

- [ ] **Step 1: Write the failing tests**

`Tests/SyncEngineTests/HistoryTests.swift`:

```swift
import GmailKit
import Store
import Testing
@testable import SyncEngine

private func makeSyncedWorld() async throws -> (ScriptedGmail, HudsonDatabase, SyncEngine) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    let gmail = ScriptedGmail()
    let engine = SyncEngine(api: gmail, database: database, account: "x")
    _ = try await engine.syncOnce()  // records cursor 100, completes empty backfill
    return (gmail, database, engine)
}

private func historyPage(_ json: String) -> HistoryPage {
    try! JSONDecoder().decode(HistoryPage.self, from: Data(json.utf8))
}

@Test func historyEventsApplyInOrderAndAdvanceCursor() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistory([historyPage("""
        {"historyId": "120", "history": [
          {"id": "110", "messagesAdded": [{"message":
            {"id": "m1", "threadId": "t1", "historyId": "110",
             "internalDate": "1000", "labelIds": ["INBOX", "UNREAD"], "snippet": "sn",
             "payload": {"headers": [{"name": "Subject", "value": "s"}]}}}]},
          {"id": "115", "labelsRemoved": [{"message":
            {"id": "m1", "threadId": "t1", "historyId": "115", "labelIds": ["INBOX"]}}]}
        ]}
        """)])
    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 2)
    let row = try #require(try await database.recentMessages(account: "x", limit: 1).first)
    #expect(row.labelIDs == ["INBOX"])  // UNREAD removed by the later event
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 120)
}

@Test func unknownLabelEventHydratesTheMessage() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setMessages(["mX": testMessage(id: "mX", historyID: "118")])
    await gmail.setHistory([historyPage("""
        {"historyId": "119", "history": [
          {"id": "118", "labelsAdded": [{"message":
            {"id": "mX", "threadId": "t9", "historyId": "118", "labelIds": ["INBOX"]}}]}
        ]}
        """)])
    _ = try await engine.syncOnce()
    // The unknown id was hydrated via metadata get, not applied blind.
    #expect(try await database.recentMessages(account: "x", limit: 5).map(\.id) == ["mX"])
}

@Test func expiredCursorResetsBackfillAndRefreshesCursor() async throws {
    let (gmail, database, engine) = try await makeSyncedWorld()
    await gmail.setHistoryError(GmailError.invalidRequest(status: 404, message: "expired"))
    await gmail.setProfileHistoryID("500")
    let report = try await engine.syncOnce()
    #expect(report.eventsApplied == 0)
    let account = try #require(try await database.primaryAccount())
    #expect(account.historyCursor == 500)       // fresh cursor recorded
    #expect(account.backfillState != "complete")  // re-list scheduled
}
```

Add the three setter methods to `ScriptedGmail` (same actor, same style):

```swift
    func setHistory(_ pages: [HistoryPage]) { historyPages = pages }
    func setMessages(_ messages: [String: GmailMessage]) {
        messagesByID.merge(messages) { _, new in new }
    }
    func setProfileHistoryID(_ id: String) {
        profile = Profile(
            emailAddress: profile.emailAddress, messagesTotal: profile.messagesTotal,
            threadsTotal: profile.threadsTotal, historyId: id)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HistoryTests`
Expected: FAIL — `pollHistory` stub returns 0 and applies nothing; `HistoryMapping` missing.

- [ ] **Step 3: Implement**

`Sources/SyncEngine/HistoryMapping.swift`:

```swift
import GmailKit
import Store

/// Flattens Gmail history records into the Store's ordered change list.
enum HistoryMapping {
    /// Order within and across records is preserved — the Store applies
    /// changes exactly in this sequence (spec §4.3).
    static func changes(from records: [HistoryRecord]) -> [HistoryChange] {
        var changes: [HistoryChange] = []
        for record in records {
            let version = Int64(record.id) ?? 0
            for added in record.messagesAdded ?? [] {
                if let snapshot = SnapshotMapping.snapshot(from: added.message) {
                    changes.append(HistoryChange(kind: .added(snapshot)))
                }
            }
            for change in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                changes.append(HistoryChange(kind: .labels(
                    id: change.message.id,
                    historyID: version,
                    labelIDs: change.message.labelIds ?? [])))
            }
            for deleted in record.messagesDeleted ?? [] {
                changes.append(HistoryChange(kind: .deleted(id: deleted.message.id)))
            }
        }
        return changes
    }
}
```

Replace `pollHistory` in `SyncEngine.swift`:

```swift
    /// Polls history.list from the stored cursor and applies each page's
    /// changes in order — one transaction per page, cursor advanced inside it
    /// (spec §4.3). Unknown ids get hydrated afterwards. A 404 means the
    /// cursor expired: M2's fallback resets backfill and re-lists (M3 brings
    /// the cheaper format=minimal reconciliation).
    private func pollHistory() async throws -> Int {
        guard let cursor = try await requireAccount().historyCursor else { return 0 }
        var applied = 0
        var pageToken: String?
        var start = String(cursor)
        do {
            repeat {
                let page = try await api.listHistory(startHistoryID: start, pageToken: pageToken)
                let changes = HistoryMapping.changes(from: page.history ?? [])
                let newCursor = page.historyId.flatMap(Int64.init) ?? cursor
                let unknownIDs = try await database.applyHistory(
                    changes, newCursor: newCursor, account: account)
                applied += changes.count
                for id in unknownIDs {
                    let message = try await api.getMessage(id: id, format: "metadata")
                    if let snapshot = SnapshotMapping.snapshot(from: message) {
                        _ = try await database.applySnapshot(snapshot, account: account)
                    }
                }
                pageToken = page.nextPageToken
                start = String(newCursor)
            } while pageToken != nil
        } catch GmailError.invalidRequest(let status, _) where status == 404 {
            // Cursor expired (spec §4.3). Blunt-but-correct M2 fallback:
            // fresh cursor, full re-list; the §4.2 guard makes re-listing safe.
            Log.transport.warning("History cursor expired; falling back to full re-list.")
            let profile = try await api.getProfile()
            try await database.applyHistory(
                [], newCursor: Int64(profile.historyId) ?? 0, account: account)
            try await database.updateBackfill(
                email: account, state: "pending", pageToken: nil, addedCount: 0)
            return 0
        }
        return applied
    }
```

(`import GmailKit` already present; `Log` is GmailKit's.)

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all pass — including Task 9's backfill tests (the `pollHistory` stub's callers were already wired).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(sync): history polling with in-order application and 404 expiry fallback"
```

---

### Task 11: CLI — `sync`, `list`, `show`

**Files:**
- Create: `Sources/HudsonCLI/Runtime.swift`
- Create: `Sources/HudsonCLI/SyncCommand.swift`
- Create: `Sources/HudsonCLI/ListCommand.swift`
- Create: `Sources/HudsonCLI/ShowCommand.swift`
- Modify: `Sources/HudsonCLI/HudsonCommand.swift` (register the three commands)

**Interfaces:**
- Consumes: everything. `Runtime` produces the wired object graph:
  - `struct Runtime { let database: HudsonDatabase; let account: AccountRecord; let client: GmailClient; let engine: SyncEngine; static func bootstrap() async throws -> Runtime }` — opens the DB at `HudsonPaths.databaseURL`, runs `AccountsMigration`, loads the primary account, builds `KeychainTokenStore` → `AccountSession` → `GmailClient` → `SyncEngine`. Throws `GmailError.auth("No account connected — run `hudson auth` first.")` when no account.
- Produces: user-facing commands. All message-derived output goes through `Sanitizer.terminalSafe`.

- [ ] **Step 1: Implement Runtime**

`Sources/HudsonCLI/Runtime.swift`:

```swift
import Foundation
import GmailKit
import Store
import SyncEngine

/// Wires the CLI's object graph for commands that need a connected account.
struct Runtime {
    let database: HudsonDatabase
    let account: AccountRecord
    let client: GmailClient
    let engine: SyncEngine.SyncEngine

    /// Opens the store, migrates legacy accounts.json if present, and builds
    /// the client stack for the primary account.
    static func bootstrap() async throws -> Runtime {
        let database = try HudsonDatabase.open(at: HudsonPaths.databaseURL)
        try await AccountsMigration.runIfNeeded(database: database)
        guard let account = try await database.primaryAccount() else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        let store = KeychainTokenStore()
        guard let clientSecret = try store.clientSecret(account: account.email) else {
            throw GmailError.auth("Keychain has no client secret — run `hudson auth` again.")
        }
        let session = AccountSession(
            account: account.email,
            oauth: OAuthClient(
                credentials: OAuthCredentials(
                    clientID: account.clientID, clientSecret: clientSecret),
                transport: URLSessionTransport()),
            store: store)
        let client = GmailClient(
            session: session, transport: URLSessionTransport(), quota: QuotaBucket())
        let engine = SyncEngine.SyncEngine(
            api: client, database: database, account: account.email)
        return Runtime(database: database, account: account, client: client, engine: engine)
    }
}
```

*(If the module-qualified `SyncEngine.SyncEngine` reads badly, rename nothing — add `typealias Engine = SyncEngine.SyncEngine` at file scope and use `Engine`. Do not rename public API.)*

- [ ] **Step 2: Implement the three commands**

`Sources/HudsonCLI/SyncCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GmailKit
import Store

/// Drives the sync engine: repeated bounded passes until backfill and the
/// current hydration window are done (or --once for a single pass).
struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Download mailbox changes into the local store."
    )

    @Flag(help: "Run exactly one bounded pass instead of syncing to completion.")
    var once = false

    @Flag(help: "Print local sync state and exit (no network).")
    var status = false

    func run() async throws {
        do {
            let runtime = try await Runtime.bootstrap()
            if status {
                try await printStatus(runtime)
                return
            }
            var totalMessages = 0
            var totalBodies = 0
            repeat {
                let report = try await runtime.engine.syncOnce()
                totalMessages += report.backfilledThisPass
                totalBodies += report.bodiesHydrated
                print(
                    "synced: +\(report.backfilledThisPass) messages, "
                    + "\(report.eventsApplied) events, +\(report.bodiesHydrated) bodies"
                    + (report.backfillComplete ? "" : " (backfill continuing…)"))
                if once || (report.backfillComplete && report.bodiesHydrated == 0) { break }
            } while true
            print("Done. \(totalMessages) messages and \(totalBodies) bodies this run.")
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }

    private func printStatus(_ runtime: Runtime) async throws {
        let account = runtime.account
        print("Account:        \(account.email)")
        print("Backfill:       \(account.backfillState) (\(account.backfilledCount) messages)")
        print("History cursor: \(account.historyCursor.map(String.init) ?? "not recorded")")
    }
}
```

`Sources/HudsonCLI/ListCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GmailKit
import Store

/// Prints the newest messages from the LOCAL store — never the network.
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent messages from the local store."
    )

    @Option(help: "How many messages to show.")
    var limit = 25

    func run() async throws {
        do {
            let runtime = try await Runtime.bootstrap()
            let rows = try await runtime.database.recentMessages(
                account: runtime.account.email, limit: limit)
            guard !rows.isEmpty else {
                print("Store is empty — run `hudson sync` first.")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            for row in rows {
                let date = Date(timeIntervalSince1970: Double(row.internalDate) / 1_000)
                let unread = row.labelIDs.contains("UNREAD") ? "●" : " "
                let from = Sanitizer.terminalSafe(row.fromLine).prefix(28)
                let subject = Sanitizer.terminalSafe(row.subject).prefix(60)
                print("\(unread) \(row.id)  \(formatter.string(from: date))  "
                    + "\(from.padding(toLength: 28, withPad: " ", startingAt: 0))  \(subject)")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
```

`Sources/HudsonCLI/ShowCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GmailKit
import Store

/// Prints one message (headers + sanitized plain text) from the local store.
struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one message from the local store."
    )

    @Argument(help: "The message id (first column of `hudson list`).")
    var id: String

    func run() async throws {
        do {
            let runtime = try await Runtime.bootstrap()
            guard let fetched = try await runtime.database.message(
                id: id, account: runtime.account.email) else {
                print("No message \(Sanitizer.terminalSafe(id)) in the local store.")
                throw ExitCode.failure
            }
            let row = fetched.row
            print("From:    \(Sanitizer.terminalSafe(row.fromLine))")
            print("To:      \(Sanitizer.terminalSafe(row.toLine))")
            print("Subject: \(Sanitizer.terminalSafe(row.subject))")
            print("Labels:  \(row.labelIDs.joined(separator: ", "))")
            print()
            if let text = fetched.plainText {
                print(Sanitizer.terminalSafe(text))
            } else {
                print("(body not downloaded yet — run `hudson sync`)")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
```

Register in `HudsonCommand.swift`:

```swift
        subcommands: [AuthCommand.self, ProfileCommand.self,
                      SyncCommand.self, ListCommand.self, ShowCommand.self]
```

- [ ] **Step 3: Build, full suite, and live verification**

Run: `swift build && swift test` — zero warnings, all tests pass.
Run (live, on this machine's connected account): `.build/debug/hudson sync` then `.build/debug/hudson list` then `.build/debug/hudson show <id-from-list>`.
Expected: sync reports the mailbox's messages, list shows them newest-first, show prints a sanitized body. Record actual output in the task notes. Then run `.build/debug/hudson sync` again — the second run should apply 0 events and add 0 messages (idempotence).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(cli): hudson sync/list/show over the local store"
```

---

### Task 12: README + spec status update

**Files:**
- Modify: `README.md` (quickstart gains `sync`/`list`/`show`; status line mentions local mailbox sync)
- Modify: `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` (§11: mark M1–M2 complete)

- [ ] **Step 1: Update README**

In the Try section, after the `profile` line, add:

```markdown
.build/debug/hudson sync       # download your mailbox into the local store
.build/debug/hudson list       # newest messages, straight from SQLite
.build/debug/hudson show <id>  # one message, sanitized, instant
```

Update the Status blockquote's last sentence to: "Today you can authenticate, sync your mailbox into a local SQLite store, and read it back instantly from the CLI."

- [ ] **Step 2: Update the spec's milestone list**

In §11, change the M1 and M2 bullets to start with `**M1 — DONE**` / `**M2 — DONE**` (leave descriptions intact).

- [ ] **Step 3: Verify quickstart accuracy and commit**

Run each changed README command against the local build (skip `auth`; account already connected).

```bash
git add README.md docs/ && git commit -m "docs: README quickstart + spec milestones for M2"
```

---

## Self-Review (completed at plan-writing time)

1. **Spec coverage (M2 slice):** GRDB + schema (§3.1) → Tasks 3–4; version guard + tombstones (§4.2) → Task 4; ordered history application + cursor-in-transaction (§4.3) → Tasks 4, 10; cursor-before-backfill + concurrent poll + unknown-id handling (§4.1) → Tasks 9–10; resumable quota-paced backfill (§4.5) → Tasks 2, 9; sanitizer pipeline + terminal safety (§3.5) → Tasks 7, 11; reads-never-block-network (§4) → Tasks 4, 11; single-flight (§4.6) → Task 9; all five M1 obligations → Tasks 1, 2, 5, 6. Deliberate M2 cuts, documented in-task: batch HTTP endpoint (spec calls it latency-only), the `format=minimal` reconciliation (M3 refines the Task 10 fallback), FTS (M4), attachments download (later), Pub/Sub push (later).
2. **Placeholder scan:** the one intentional stub (`pollHistory` returning 0 in Task 9) is explicitly labeled as Task 10's work in both tasks — not a dangling TBD. No other placeholders.
3. **Type consistency:** `MessageSnapshot`, `HistoryChange`, `SnapshotOutcome`, `MessageRow`, `AccountRecord`, `SanitizedBody`, `GmailAPI` signatures, and `SyncReport` fields are used with identical names/types across Tasks 4–11; `ScriptedGmail` setters added in Task 10 are declared in that task. `HudsonDatabase.applyHistory([], newCursor:account:)` doubles as the cursor-write primitive (used by Tasks 9–10) — same signature everywhere.
```
