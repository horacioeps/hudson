# Store

`Sources/Store/` — the SQLite mailbox. Schema, migrations, every read and
write, full-text search, and the two durable queues. Depends only on GRDB;
knows nothing about Gmail or the network.

This is the largest library target and the one most changes touch. If you are
adding a feature that persists anything, you are working here.

## Opening a database

```swift
import Store

let db = try HudsonDatabase.open(at: HudsonDatabase.defaultDatabaseURL)
let memory = try HudsonDatabase.inMemory()   // tests
```

`open(at:)` creates the file if needed, enables WAL, and runs any pending
migrations. `defaultDatabaseURL` is
`~/Library/Application Support/Hudson/hudson.sqlite` — the file the CLI and
the app share.

`HudsonDatabase` is a `Sendable` struct wrapping a GRDB `DatabaseWriter`. Every
public API on it is `async`. Other modules must never reach for `.writer`
directly.

## Schema

Ten migrations, `v1` through `v10`, in `Migrations.swift`. **Migrations are
append-only** — never edit one that has shipped; installed databases have
already run it.

### Canonical tables — server truth

| Table | Primary key | Holds |
|---|---|---|
| `accounts` | `email` | client id, consent date, history cursor, backfill state + page token |
| `threads` | `(account_email, id)` | thread id, last message timestamp |
| `messages` | `(account_email, id)` | thread id, `history_id`, `internal_date` (ms), From/To/Subject/snippet, `has_body`, `has_attachment`, `rfc822_message_id`, `references_header` |
| `message_bodies` | `(account_email, message_id)` | `raw_html` blob, `plain_text`, `sanitizer_version`, `cid_references`, `remote_urls` |
| `labels` | `(account_email, id)` | label id → name |
| `message_labels` | `(account_email, message_id, label_id)` | the canonical label set |
| `attachments` | `(account_email, message_id, attachment_id)` | filename, MIME type, size |
| `tombstones` | `(account_email, message_id)` | ids known to be gone server-side |

`message_bodies`, `message_labels`, and `attachments` cascade-delete from
`messages`.

### Derived tables — maintained incrementally

| Table | Why it exists |
|---|---|
| `thread_rollup` | The inbox list reads this and **only** this: newest message's subject/snippet/sender, message count, and the overlay-aware `unread`/`in_inbox` flags. Zero joins, zero aggregation at read time. |
| `message_seq` | Maps the composite `(account_email, message_id)` key to a dense integer, because FTS5's implicit rowid must be an integer. |
| `fts_messages` | FTS5 virtual table over subject/from/to/body. `unicode61 remove_diacritics 2`, `prefix='2 3 4'`. |
| `split_rules` | Ordered predicates (`sender`/`domain`/`listid`/`category`) mapping a thread to a split tab. |

Derived tables are maintained by `ThreadRollup` and `FTSIndex` on every write
path. If you add a write path, it must maintain them too — that is the price
of the read-time speed.

### Queues — durable state machines

| Table | States | Guarded by |
|---|---|---|
| `mutation_queue` | `pending` → `in_flight` | unique index on `(account, message, label)`; `BEFORE INSERT` **and** `BEFORE UPDATE` triggers rejecting bad `op`/`state` |
| `send_jobs` | `pending`/`held` → `in_flight` → `sent`/`failed` | column-level `CHECK`; unique index on `(account, rfc822_message_id)` |

### AI tables

`ai_config` (per-feature model, base URL, and the opt-in flag),
`ai_artifacts` (cached summaries/answers keyed by
`(account, kind, artifact_key, model, prompt_version)`), and
`ai_artifact_sources` (which messages fed an artifact, so deleting a message
can purge derived AI content).

## Reads

```swift
try await db.recentMessages(account: email, limit: 50)          -> [MessageRow]
try await db.message(id:account:)                                -> MessageRow?
try await db.messageBody(id:account:)                            -> MessageBody?
try await db.attachments(messageID:account:)                     -> [AttachmentMeta]
try await db.labels(account:)                                    -> [LabelRecord]
try await db.threadsWithLabel(...)                               -> [ThreadRow]
try await db.sendAsFromLine(account:)                            -> String?
```

`MessageRow.labelIDs` is the **effective** label set — canonical labels with
pending `mutation_queue` deltas applied. Callers never compose the overlay
themselves.

### Inbox list

```swift
try await db.inboxThreads(
    account: email,
    split: "primary",       // nil for all splits
    limit: 50,
    before: (lastMessageAt: row.lastMessageAt, threadID: row.threadID)  // next page
) -> [ThreadRow]
```

One index-backed query over `thread_rollup`:
`WHERE account_email = ? AND in_inbox = 1 [AND split_key = ?] ORDER BY
last_message_at DESC, thread_id DESC LIMIT ?`.

**Keyset pagination, not `OFFSET`.** `before` is the previous page's last row;
the row-value comparison `(last_message_at, thread_id) < (?, ?)` makes each
page an indexed range seek, so paging deep stays flat instead of degrading.

**The overlay composes for free.** `thread_rollup.in_inbox`/`unread` are
themselves overlay-aware, and the mutation queue recomputes them in the same
transaction as an enqueue or a retirement. An optimistic archive drops its
thread from this list on the very next call, and this query never touches
`mutation_queue`.

### Search

```swift
try await db.searchMessages(
    account: email, query: "quarterly", limit: 50, scope: .inbox
) -> [SearchHit]
```

- **2-character floor.** A shorter query returns `[]` without touching the
  database — the `prefix='2 3 4'` index only accelerates prefixes of 2+, so a
  1-char query would force a full index scan on every keystroke.
- **Injection-safe.** FTS5's `MATCH` is its own query language (`AND`/`OR`/
  `NOT`/`NEAR`, column filters, `^`, `*`). `query` is untrusted, so it is
  rewritten into a safe MATCH expression rather than interpolated.
- **bm25-ranked**, joined back through `message_seq` to `messages`.
- `scope: .inbox` adds an `EXISTS` filter over `EffectiveLabels.fragment`, so
  an optimistically-archived message drops out of an in-inbox search
  immediately.

### Observation

Live queries backed by GRDB `ValueObservation`, as `AsyncSequence`s:

```swift
for try await rows in db.observeInboxThreads(account:split:limit:) { … }
for try await messages in db.observeThread(threadID:account:) { … }
for try await rules in db.observeSplitRules(account:) { … }
for try await count in db.observePendingCount(account:) { … }
for try await count in db.observeInboxUnreadCount(account:) { … }
```

These are what make the UI reactive: a background sync writes, and the inbox
list updates without anyone telling it to.

## Writes

```swift
try await db.applySnapshot(snapshot, account:)   -> SnapshotOutcome
try await db.applySnapshots([snapshot], account:) -> Int      // one commit
try await db.applyHistoryChanges(changes, account:) -> [String]  // unknown ids
try await db.advanceCursor(to:account:)
try await db.applyHistory(_:newCursor:account:)
try await db.saveBody(messageID:account:body:attachments:…)
try await db.deleteVanishedMessage(id:account:)
try await db.upsertLabels(_:account:)
```

**Version guard (spec §4.2).** `applySnapshot` compares the incoming
`history_id` against the stored row and refuses to overwrite newer state.
This is what makes "when in doubt, re-list" safe: re-applying an already-known
message is a no-op, so recovery paths never risk clobbering.

**Batching.** `applySnapshots` commits once per page rather than once per
message — the control against a `ValueObservation` storm during a multi-hour
backfill. Each message still gets its own `SAVEPOINT`, so one bad message
cannot poison the page.

## Mutation queue

```swift
try await db.enqueueMutation(messageID:labelID:op:account:now:)
try await db.pendingMutations(account:)               -> [PendingMutation]
try await db.claimPendingBatch(account:limit:)        -> [PendingMutation]
try await db.markInFlight(mutationIDs:expectedHistoryID:account:)
try await db.retireConfirmedMutations(account:)       -> Int
try await db.dropMutation(id:account:)
```

`enqueueMutation` resolves collisions rather than stacking rows:

| Existing row | New op | Result |
|---|---|---|
| none | any | insert |
| `pending`, same op | same | no-op (idempotent) |
| `pending`, opposite op | opposite | delete — net no-op, nothing was ever sent |
| `in_flight`, opposite op | opposite | **overlay forward**: flip `op`, reset to `pending`, clear the expected historyId |

That last row is subtle and deliberate. An `in_flight` delta has already been
sent and cannot be recalled, so deleting it would silently drop the new intent
— there would be nothing left in the queue to send it. Overlaying keeps the
unique index satisfied and the effective-label read correct throughout.

Every branch that changes the queue also recomputes the affected thread's
rollup flags **in the same transaction**. That is what makes an optimistic
archive drop the thread from `inboxThreads` instantly.

See [optimistic-mutations.md](../explanation/optimistic-mutations.md) for the
full model.

## Send queue

```swift
try await db.enqueueSend(account:rfc822MessageID:threadID:rawMIME:holdUntil:now:) -> Int64
try await db.claimSendable(account:now:)     -> [SendJob]   // past the undo hold
try await db.markSendInFlight(id:account:)
try await db.markSent(id:account:sentMessageID:)  -> Bool
try await db.markSendFailed(id:account:)          -> Bool
try await db.inFlightSendJobs(account:)           -> [SendJob]
try await db.cancelSend(id:account:now:)          -> Bool    // undo-send
try await db.sendJob(id:account:)                 -> SendJob?
```

`hold_until` is the undo-send window end, in ms since epoch. `cancelSend`
refuses once the send may be in motion. Driven by
[`Outbox.SendService`](outbox.md).

## Sanitizer

```swift
public enum Sanitizer {
    public static let version = 1
    public static func sanitize(html: Data?, plainText: String?) -> SanitizedBody
    public static func terminalSafe(_ s: String, singleLine: Bool) -> String
}
```

The single choke point for untrusted mail content (spec §3.5). `SanitizedBody`
has **no public initializer** — it is only ever the output of `sanitize`, so
raw mail cannot reach the terminal or the FTS index by another route.

`sanitize` prefers the sender's `text/plain` part and falls back to stripping
HTML. It decodes UTF-8 lossily (U+FFFD for invalid bytes) to prevent evasion
via malformed input, and inventories `cid:` and remote URL references —
deduped and capped at 200 per category, so padding cannot be used to evade —
so the renderer can block remote loads.

Bump `version` on any behavior change; stored bodies re-derive.

`terminalSafe` wraps anything a CLI command prints. Sender names, subjects,
and label names are all attacker-influenced.

## Types

| Type | Notes |
|---|---|
| `MessageRow` | One message with **effective** labels |
| `MessageBody` | `plainText`, `rawHTML`, `remoteURLs`, `cidReferences` |
| `ThreadRow` | One inbox list row, straight from `thread_rollup` |
| `SearchHit` | A ranked FTS hit |
| `MessageSnapshot` | The value SyncEngine writes; carries `historyID` for the version guard |
| `SnapshotOutcome` | inserted / updated / ignored-as-stale |
| `HistoryChange` | One decoded history event |
| `AccountRecord` | Account row incl. backfill progress |
| `SplitRule` / `SplitPredicateKind` | Split-tab routing |
| `PendingMutation` / `LabelOp` | Queue rows |
| `SendJob` / `SendJobState` | Send queue rows |
| `AttachmentMeta` | Attachment metadata (no bytes) |

## Internal helpers

Not part of the public API, but the pieces you will most often need to change:

- `ThreadRollup` — `maintainRollup`, `recomputeThreadRollup`,
  `recomputeThreadFlags`. Every write path calls into here.
- `FTSIndex` — incremental FTS maintenance.
- `EffectiveLabels.fragment` — the single shared SQL shape for "canonical
  labels ∪ pending adds − pending removes", used by four call sites. Change
  the overlay rule here, not at the call sites.
- `SplitInbox` — rule evaluation.
- `AIStore` / `AIArtifacts` — AI config and artifact cache + purge.
- `AccountsImport` / `AccountsMigration` — one-time import of the legacy
  M1 `accounts.json`.

## Tests

`Tests/StoreTests/` — 24 files. `MigrationTests`, `QueryLayerMigrationTests`,
`MutationQueueMigrationTests`, and `BackfillWindowMigrationTests` cover schema
evolution specifically; `VersionGuardTests` covers the anti-clobber rule;
`OverlayReadTests` covers the effective-label composition;
`SanitizerTests` covers hostile input.

**Any schema change needs a migration test.** `Tests/StoreTests/Support/TestSeed.swift`
seeds a realistic database.

## Related

- [SyncEngine](syncengine.md) — the main writer
- [Outbox](outbox.md) — drives `send_jobs`
- [optimistic-mutations.md](../explanation/optimistic-mutations.md)
- [local-first-sync.md](../explanation/local-first-sync.md)
