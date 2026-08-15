# SyncEngine

`Sources/SyncEngine/` — four files that own everything moving between Gmail and
the local [Store](store.md): backfill, incremental history polling, body
hydration, and draining the triage queue.

Depends on `GmailKit` and `Store`. Owns no persistent state of its own —
**all cross-pass state lives in SQLite**, so a crash resumes cleanly from
whatever the database says.

| File | Role |
|---|---|
| `SyncEngine.swift` | The read-path actor: backfill, history, hydration |
| `MutationFlusher.swift` | The write-path actor: drains `mutation_queue` to Gmail |
| `SnapshotMapping.swift` | `GmailMessage` → `MessageSnapshot` |
| `HistoryMapping.swift` | Gmail history records → `HistoryChange` |

## SyncEngine

```swift
public actor SyncEngine {
    public init(
        api: any GmailAPI, database: HudsonDatabase, account: String,
        pageSize: Int = 100, hydrationBatch: Int = 25,
        prefetchWindowDays: Int = 90, backfillLookbackDays: Int = 90,
        now: @escaping @Sendable () -> Date = { Date() })

    public func syncOnce(maxBackfillPages: Int = 5) async throws -> SyncReport
    public func hydrate(messageID: String) async throws -> Bool
}
```

### `syncOnce`

One bounded pass, in this order:

```
ensureCursor  →  pollHistory  →  backfill (≤5 pages)  →  hydrateBodies (≤25)
```

Bounded on purpose: each pass does a fixed amount of work and returns, so the
caller controls cadence and nothing runs unbounded in the background.

**Single-flight.** A second concurrent call coalesces to an empty `SyncReport`
rather than racing (spec §4.6). Actors are re-entrant, so the guard is
explicit — actor isolation alone would not prevent two overlapping passes.

```swift
public struct SyncReport: Sendable, Equatable {
    public var backfilledThisPass = 0
    public var eventsApplied = 0
    public var bodiesHydrated = 0
    public var backfillComplete = false
}
```

An all-zero report also means "coalesced".

### ensureCursor

Records `profile.historyId` **before** the first list call (spec §4.1). That
ordering is what makes incremental sync cover everything that changes during a
multi-hour backfill: the cursor predates the listing, so no event falls
between them.

A `historyId` that will not parse as an integer throws rather than silently
seeding `0` — a zero cursor would make incremental sync believe history starts
at the very beginning.

### pollHistory

Pages through `history.list` from the stored cursor, applies each page's
changes in order, then advances the cursor **exactly once, after the last
page**.

That single commit is load-bearing. Gmail reports the *current mailbox*
`historyId` on every page of a poll — not "as of this page" — so committing
per page would jump the cursor to its final value on page one while pages
2..N were still unapplied. A crash mid-pagination would then silently lose
them. Instead every page applies via `applyHistoryChanges` (cursor untouched),
and `advanceCursor` runs once at the end. A crash anywhere in the loop leaves
the cursor where it was, and the next pass re-polls from there — safe because
of the §4.2 version guard.

The page token is paired with a **fixed** `startHistoryId` for the whole loop:
a Gmail page token continues the listing that created it, so varying the start
between pages is undefined.

**Cursor expiry.** A 404 from `listHistory` — and only from `listHistory` —
means the cursor aged out. The fallback: fetch a fresh cursor, reset
`backfill_state` to `pending`, and let a later pass re-list. Re-listing is
safe, not lossy, because the version guard makes re-applying a known message a
no-op.

The resulting re-list is deliberately **deferred to the next pass**
(`historyExpiredThisPass`). Running backfill inline in the same pass could
flip the state straight back to `complete` before the caller ever observed the
reset.

Unknown message ids referenced by a history event are hydrated with a
`format: "metadata"` fetch. A 404 there is expected and silent — the message
vanished between the event and the fetch.

### backfill

Paginates `messages.list` up to `maxBackfillPages` per pass, fetching each
message at `format: "metadata"`.

**The sync window.** Backfill is bounded by a Gmail `q` filter —
`after:<epoch>`, computed as `consentedAt - backfillLookbackDays` (90 days by
default). Backfill's job is to make the mailbox *readable fast*, not to mirror
it: every listed message costs a `messages.get`, so an old account would spend
hours fetching archive nobody is about to open. The lookback (rather than a
cut at the connect date itself) is what keeps first launch from showing an
empty inbox. Anything newer arrives through `pollHistory`, which is
unfiltered — the window never applies to live mail.

The anchor is `consentedAt`, **not** `now()`. Gmail evaluates `q` server-side
on every page request, so a relative window (`newer_than:90d`) would drift
between pages and a stored page token would resume into a listing whose result
set no longer matched. A fixed epoch second gives every page — including one
resumed days later — provably the same filter.

Set `backfillLookbackDays: 0` to disable the bound and list the whole mailbox.

**One commit per page**, not per message — the control against a SwiftUI
`ValueObservation` storm during a long backfill. Each message still gets its
own `SAVEPOINT`. A single bad message is logged and skipped so the page token
still advances.

### hydrateBodies / hydrate

Fetches full bodies newest-first within `prefetchWindowDays`, in batches of
`hydrationBatch`. Per message: `getMessage(format: "full")` → `extractContent`
→ `Sanitizer.sanitize` → `saveBody`.

`hydrate(messageID:)` is that same pipeline for **one** message, exposed
publicly so there is exactly one body-fetch code path. The reading pane calls
it on demand the moment you open a thread, which is why opening a message is
instant even while the background backfill is still hours from reaching it.

The two callers split error handling deliberately:

- **`hydrateBodies`** catches `GmailError` around each id — one bad message
  must never stall the other 24 in the batch.
- **`hydrate`** rethrows everything except a 404, because a single on-demand
  call has no "next id" to fall through to. The UI is expected to `try?` it.

A **404 tombstones** the message via `deleteVanishedMessage` rather than
skipping it. Skipping would leave the id at the head of
`messageIDsNeedingBodies`' work-list forever, failing every future sync with
the same 404.

### GmailAPI

```swift
public protocol GmailAPI: Sendable {
    func getProfile() async throws -> Profile
    func listMessages(pageToken: String?, maxResults: Int, query: String?) async throws -> MessageListPage
    func getMessage(id: String, format: String) async throws -> GmailMessage
    func listHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage
    func listLabels() async throws -> [GmailLabel]
    func modify(id: String, addLabelIDs: [String], removeLabelIDs: [String]) async throws -> GmailMessage
    func batchModify(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws
}

extension GmailClient: GmailAPI {}
```

The seam that lets tests script a server (`Tests/SyncEngineTests/Support/ScriptedGmail.swift`)
instead of mocking HTTP.

## MutationFlusher

```swift
public actor MutationFlusher {
    public init(api: any GmailAPI, database: HudsonDatabase, account: String)
    public func start() async
    public func flushOnce() async throws -> FlushReport
}

public struct FlushReport: Sendable, Equatable {
    public var flushed: Int
    public var retired: Int
    public var dropped: Int
}
```

Drains `mutation_queue` to Gmail. Per pass: claim a batch of `pending` rows →
send via `modify` → `markInFlight` with the returned `historyId` as the
retirement gate → `retireConfirmedMutations` for anything whose echo has
landed. Terminal failures are dropped and truth re-derived.

Single-flight, same as `SyncEngine`. `start()` runs the loop continuously; the
CLI calls `flushOnce()` after a triage command instead.

The retirement gate is the interesting part — see
[optimistic-mutations.md](../explanation/optimistic-mutations.md).

## Mapping

`SnapshotMapping.snapshot(from: GmailMessage) -> MessageSnapshot?` is the
single place that knows how to pull From/To/Subject/snippet/labels, the
`history_id`, and the RFC threading headers (`Message-ID`, `References`) off a
Gmail message. Backfill, history hydration, and body hydration all route
through it. Returns `nil` for a message it cannot map.

`HistoryMapping.changes(from:)` decodes Gmail's history records into
`HistoryChange` values.

## Wiring it up

```swift
let engine = SyncEngine(api: client, database: db, account: email)
let flusher = MutationFlusher(api: client, database: db, account: email)

let report = try await engine.syncOnce()
let flush  = try await flusher.flushOnce()
```

The CLI builds this in `Runtime.bootstrap()`; the app builds it in
`SyncBootstrap.makeStack(database:account:)`.

## Tests

`Tests/SyncEngineTests/` — `BackfillTests`, `HistoryTests`, `PollCursorTests`,
`HydrationTests`, `FlusherTests`, `CategoryPersistenceTests`,
`SnapshotMappingTests`, plus `Support/ScriptedGmail.swift`.

## Related

- [local-first-sync.md](../explanation/local-first-sync.md) — why it works this way
- [Store](store.md) — where every pass writes
- [GmailKit](gmailkit.md) — the client behind `GmailAPI`
