# Why the mailbox is a local database

Hudson never renders from a network response. Every list, thread, and search
result comes out of SQLite. This page explains why that choice drives most of
the rest of the architecture, and what it costs.

Spec §4. Implemented in `SyncEngine/` and `Store/`.

## The problem

Gmail's API is a fine API and a terrible thing to render from.

- **Latency is not yours to control.** A `messages.list` round trip is tens to
  hundreds of milliseconds on a good connection. Superhuman-class feel is a
  sub-100 ms budget for the *whole* interaction. There is no room.
- **Quota is small and shared.** 6,000 units/minute/user, and a single
  `messages.get` costs 20. Scrolling an inbox by fetching is not viable.
- **There is no search you can use.** Gmail's server search is a network call
  per keystroke. Search-as-you-type over the network is not search-as-you-type.
- **Offline is a real state.** Planes, trains, bad hotel wifi. A mail client
  that cannot show you mail you already received is broken.

## The design

One SQLite file is the source of truth for every read. The network is a
background process that keeps it current.

```
Gmail ──► SyncEngine ──► Store (SQLite) ──► ValueObservation ──► SwiftUI
                            ▲
                            └── the only thing the UI ever reads
```

The UI does not know the network exists. `InboxModel` observes a query. When a
background pass writes, the observation fires and the list updates. No loading
spinner, no refresh button in the read path, no error state for "the network
was slow" — because no read ever waited on the network.

That inversion is what buys everything else: a CLI and an app as peers over
the same file, full-text search that responds in a keystroke, and triage that
works on a plane.

## The three passes

`SyncEngine.syncOnce()` is one bounded pass — bounded on purpose, so the
caller controls cadence and nothing runs unbounded in the background.

### Backfill: get readable fast, don't mirror

The naive backfill lists the entire mailbox. For a ten-year-old account that
is hundreds of thousands of `messages.get` calls at 20 units each — hours of
work to cache archive nobody is about to open.

So backfill is bounded by a Gmail `q` filter: `after:<epoch>`, computed as
90 days before the account was connected. That turns hours into minutes. The
lookback (rather than a cut at the connect date itself) is what keeps first
launch from showing an empty inbox — there is mail to read the moment
onboarding finishes.

Anything newer than the window arrives through history polling, which is
unfiltered. The window never applies to live mail.

**The anchor is `consentedAt`, not `now()`, and that is load-bearing.**
Backfill paginates across many passes spread over hours or days, and Gmail
evaluates `q` server-side on *every* page request. A relative window
(`newer_than:90d`) would drift between pages, so a stored page token would
resume into a listing whose result set no longer matched the one that produced
it. A fixed epoch second gives every page — including one resumed days later —
provably the same filter.

Progress is stored in the `accounts` row (`backfill_state`,
`backfill_page_token`), so a quit mid-backfill resumes where it left off.

### History polling: the incremental path

Gmail's `history.list` gives you everything that changed since a cursor. Cheap
(2 units), and the normal steady-state path.

**The cursor is recorded before the first list call**, not after. That
ordering is what makes incremental sync cover everything that changes *during*
a multi-hour backfill: the cursor predates the listing, so no event can fall
between them.

**The cursor is committed once per poll, not per page.** This is the subtle
one. Gmail reports the *current mailbox* `historyId` on every page of a poll —
not "as of this page". So a per-page commit would jump the cursor to its final
value on page one while pages 2..N were still unapplied, and a crash
mid-pagination would silently lose them. Instead each page applies its changes
with the cursor untouched, and `advanceCursor` runs once after pagination
finishes. A crash anywhere in the loop leaves the cursor where it was, and the
next pass re-polls from there.

That is only safe because of the version guard, below.

**Cursor expiry.** Gmail expires history cursors. A 404 from `listHistory` —
and only from `listHistory`, never from a `getMessage` — means the cursor aged
out. The fallback is blunt and correct: fetch a fresh cursor, reset backfill to
`pending`, re-list. Re-listing costs quota but cannot lose or corrupt
anything.

The re-list is deliberately deferred to the *next* pass. Running it inline
would immediately re-list and could flip `backfill_state` back to `complete`
before the caller ever observed the reset.

### Hydration: bodies on demand and in the background

Listing gives metadata; bodies need a separate `messages.get(format: "full")`
at 20 units each. Hydration walks newest-first within a 90-day prefetch
window, 25 messages per pass.

But a background walk is far too slow to be the only path — a fresh account
would take a long time to reach any particular message, and opening a thread
would show "loading" for something that could be fetched in 200 ms. So
`hydrate(messageID:)` is the same pipeline for one message, called **on
demand** the instant you open a thread. That is why reading works immediately
on a mailbox that is still hours from being fully cached.

One pipeline, two callers, and they split error handling deliberately: the
batch catches per-message errors so one bad id cannot stall the other 24; the
on-demand call rethrows, because it has no "next id" to fall through to.

A 404 during hydration **tombstones** the message rather than skipping it.
Skipping would leave the id at the head of the work-list forever, failing
every future sync with the same 404.

## The version guard

Every write carries the `history_id` it came from, and `applySnapshot` refuses
to overwrite a row with a *newer* stored id. Re-applying a stale snapshot is a
no-op.

This one rule is what makes the rest of the design tractable. It means:

- Re-listing during expiry recovery cannot clobber newer state.
- Re-polling after a crash cannot clobber newer state.
- Backfill and history polling can run **concurrently** without coordination —
  they can both touch the same message in either order, and the newer write
  wins regardless of arrival order.

Without it, every recovery path would need to reason about ordering. With it,
"when in doubt, re-fetch" is always safe. Recovery strategies get to be blunt.

## Serving reads fast

Correct data is not the same as fast reads. Two denormalizations do that work:

**`thread_rollup`** — one row per thread carrying the newest message's
subject, snippet, and sender, the message count, and the overlay-aware
`in_inbox`/`unread` flags. The inbox list is
`WHERE account_email = ? AND in_inbox = 1 ORDER BY last_message_at DESC LIMIT ?`
against an index. No joins. No aggregation. No `mutation_queue` lookup.

Pagination is **keyset**, not `OFFSET`: `before` is the previous page's last
row, and `(last_message_at, thread_id) < (?, ?)` makes each page an indexed
range seek. Cost stays flat as you page deeper instead of degrading.

**`fts_messages`** — an FTS5 index over subject/from/to/body, `unicode61
remove_diacritics 2`, `prefix='2 3 4'`. Search is a local `MATCH`, bm25-ranked.

Both are maintained incrementally on every write path. That is the price: any
new write path must maintain them too, or the inbox goes stale in a way no
compiler will catch.

## Batching, and the observation storm

During a multi-hour backfill the engine writes constantly, and every write
fires every `ValueObservation` watching those tables. Committing per message
would repaint the entire SwiftUI inbox thousands of times.

So `applySnapshots` commits **once per page** (100 messages) rather than once
per message. Each message still gets its own `SAVEPOINT`, so one bad message
cannot poison the page.

The auto-sync loop tightens to a 2-second interval while catching up and
relaxes to 30 seconds once caught up — a fresh mailbox fills in about a minute
instead of fifteen — and `isCatchingUp` drives an honest "Getting your mail…"
footer rather than claiming "All synced" mid-hydration.

## Quota as a scheduling problem

At 6,000 units/min shared with every other client on the account, quota is a
resource to schedule, not a limit to hit. `QuotaBucket` is a rolling-minute
limiter with two lanes: `.interactive` (someone waiting on a star or a send)
drains ahead of `.background` (polling, backfill), and background is admitted
only up to a reserved sub-budget so it can never saturate the window.

That is why a foreground archive stays instant while a fresh account is
backfilling thousands of messages.

## What it costs

- **Disk.** A real mailbox on a real disk. The 90-day window bounds it.
- **Derived-table maintenance, forever.** `thread_rollup`, `fts_messages`, and
  `message_seq` must be maintained correctly by every write path. This is why
  `Store` is the largest library target and why schema changes need migration
  tests.
- **Migrations are permanent.** Ten and counting. Append-only, no exceptions.
- **Eventual consistency is visible.** A label changed on your phone appears
  within a poll interval, not instantly. The honest fix is honest UI —
  `pendingCount`, `isCatchingUp` — not pretending otherwise.

## See also

- [SyncEngine reference](../reference/syncengine.md) — the API
- [Store reference](../reference/store.md) — schema and queries
- [optimistic-mutations.md](optimistic-mutations.md) — the write path that composes over this
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — how it all fits
