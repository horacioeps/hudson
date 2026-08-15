# Why triage is a queue, not a write

How archiving a thread feels instant while still being correct when the
network is slow, absent, or lying — and why the obvious simpler designs fail.

Spec §5. Implemented in `Store/MutationQueue.swift`,
`Store/EffectiveLabels.swift`, `Store/ThreadRollup.swift`, and
`SyncEngine/MutationFlusher.swift`.

## The problem

You press `e`. The thread should leave the inbox *now* — not in 300 ms, not
when Gmail acknowledges, not "eventually". Superhuman-class feel means the row
is gone before your finger leaves the key.

But the truth about that thread's labels lives on Google's servers, and you
are not the only writer. Your phone might archive it a second later. A filter
might label it. Gmail's own web UI might mark it read. Any design that treats
the local database as authoritative will, sooner or later, overwrite something
it should not have.

So: instant local effect, server remains the source of truth. Those pull in
opposite directions.

### Why the simple designs fail

**Write locally, sync later.** Write `INBOX` off the message row immediately,
push to Gmail in the background. Instant, and wrong: the local row is now
indistinguishable from server truth. When the next history poll brings back a
snapshot, there is no way to tell "this label change is mine, unconfirmed"
from "this is what the server said". Concurrent changes from another device
either clobber yours or get clobbered by it, and nothing can tell which
happened.

**Write locally, keep a dirty flag.** Better, but the flag has to be
per-message-per-label, has to survive a crash, has to record *which direction*
the change went, and has to know when it is safe to clear. At which point you
have built a queue — just an undisciplined one, sharing a table with canonical
data.

**Await the network.** Correct, and unusable. Every archive costs a round
trip, and offline means no triage at all.

## The design

Keep two things separate and compose them at read time.

```
canonical tables          message_labels — only ever written by SyncEngine,
(server truth)            from what Gmail actually said

    +

overlay                   mutation_queue — one row per live, unconfirmed
(local intent)            local delta: (message, label, add|remove)

    =

effective labels          what the user sees
```

**Triage never writes canonical tables.** `enqueueMutation` inserts one row
into `mutation_queue` and nothing else touches `message_labels`. Server truth
stays pristine, so a later snapshot can be applied without any "is this mine?"
ambiguity — the question never arises, because local intent was never mixed in.

**Reads compose the overlay.** Every effective-label read is
canonical ∪ pending-adds − pending-removes. That composition lives in exactly
one place, `EffectiveLabels.fragment`, shared by all four call sites
(`StoreReads.messageRow`, `SearchQuery`'s `.inbox` scope, `AIStore.sentMessages`,
`ThreadRollup.effectiveLabelPresentInThread`). Before that shared fragment
existed the same three-subquery shape was hand-duplicated four times — one
rule to get right, not four.

## Making it instant, not just correct

An overlay that only applies to per-message reads would still leave the inbox
list stale, because the inbox list does not read messages — it reads
`thread_rollup`, a denormalized table, with no joins and no aggregation. That
is what makes it fast.

So `thread_rollup.in_inbox` and `.unread` are themselves overlay-aware, and
**every branch of `enqueueMutation` that changes the queue recomputes the
affected thread's flags in the same transaction.** One commit, both effects.
The thread drops out of `inboxThreads` on the very next call — before the
archive has gone anywhere near Gmail — and the inbox query itself never has to
touch `mutation_queue`.

The same recompute runs on `retireConfirmedMutations` and `dropMutation`, so
the rollup stays in lockstep with the queue in both directions rather than
waiting for some unrelated event to eventually touch that thread.

### Thread-level vs message-level

`in_inbox`/`unread` are OR-aggregates: true if *any* message in the thread
still effectively carries the label. So archiving only a thread's newest
message is a silent no-op on a multi-message thread — an older message still
carries `INBOX`, the rollup recomputes right back to `true`, and the thread
never leaves the list.

`Triage.archiveThread` and `markReadThread` therefore enqueue a delta on every
message in the thread that carries the label. Starring and marking-unread stay
scoped to one message, because that is what they are in Gmail itself.

This is the kind of bug that only shows up on real mailboxes with real
threads, which is why it is called out here rather than left to be
rediscovered.

## Collisions

Two rapid presses of `e`, or an archive-then-unarchive, must not stack rows.
A unique index on `(account, message, label)` enforces at most one live delta,
and `enqueueMutation` resolves the collision:

| Existing | New op | Result |
|---|---|---|
| none | any | insert |
| `pending`, same op | same | no-op — idempotent |
| `pending`, opposite | opposite | **delete** — net no-op, nothing was ever sent |
| `in_flight`, opposite | opposite | **overlay forward** — flip `op`, reset to `pending` |

That last row is the subtle one, and it was a real bug caught in review.

An `in_flight` delta has already been sent to Gmail and cannot be recalled.
Deleting it — the obvious symmetric move — would silently drop the new intent:
there would be nothing left in the queue to send the inverse, so the user's
un-archive would simply never happen. A deterministic lost update.

Overlaying forward instead keeps the unique index satisfied (same row, not a
second insert), keeps the effective read correct throughout (`messageRow`
treats every queue row as live regardless of state), and lets the flusher send
the inverse normally once it claims the row again.

## Retirement: on echo, not on 2xx

The flusher sends a batch, and Gmail's `modify` response carries the new
`historyId`. That id is recorded as the delta's `expected_history_id` — the
**retirement gate**.

The delta is dropped only once the account's history cursor has advanced past
that id. Not when the HTTP call returns 200.

The distinction matters because retiring on 2xx would drop the overlay while
canonical truth still says `INBOX`. The next read would compose
canonical(INBOX) ∪ nothing = still in the inbox, and the row would visibly
flicker back into the list until the next history poll caught up. Waiting for
the echo means the overlay is removed at exactly the moment the canonical
write replaces it — no window where neither is true.

```
enqueue ──► pending ──► in_flight ──► (echo lands) ──► retired
   │                        │
   │                        └─ expected_history_id recorded here
   │
   └─ thread_rollup recomputed, same transaction → row gone from the inbox
```

## Crash safety

`mutation_queue` is a real table with an explicit state machine, so every
interruption has a defined resume:

- **Crash before send** — the row is `pending`. Next flush claims it. The
  overlay was never lost, so the UI still shows the archive.
- **Crash after send, before `markInFlight`** — the row is still `pending`, so
  it is re-sent. Safe: Gmail label modifications are idempotent. Adding
  `STARRED` twice is one star.
- **Crash after `markInFlight`, before retirement** — the row is `in_flight`
  with its gate recorded. The next `retireConfirmedMutations` compares against
  the cursor and retires it if the echo has landed.

Idempotence is what makes this simpler than the send path. Sending an email
twice sends two emails; that is why [Outbox](../reference/outbox.md) needs a
probe protocol and this does not.

Schema-level guards back it up: a `BEFORE INSERT` **and** a `BEFORE UPDATE`
trigger reject any row whose `op`/`state` is not a legal value. The update
twin was added later, in `v9` — the insert trigger alone left an `UPDATE` that
corrupted `state` sailing through unguarded, which a real `CHECK` constraint
would have caught. SQLite cannot add a `CHECK` to an existing table without a
full rebuild, hence two triggers.

## Undo

`hudson undo <id>` enqueues the inverse delta. Because opposite-op collision
handling already does the right thing, undo needs no special case: if the
original is still `pending` it cancels outright and nothing is ever sent; if
it has gone `in_flight` it overlays forward and the inverse is sent normally.

## What this costs

- **Every effective-label read pays for the overlay composition.** Mitigated
  by keeping it to one shared SQL fragment and by pre-composing the hot path
  into `thread_rollup`.
- **Every write path must maintain the rollup.** Forgetting the recompute in a
  new write path is the most likely way to introduce a stale-inbox bug here.
- **The queue is one more thing that can be wrong.** `hudson pending` exists
  so it is inspectable rather than mysterious.

Worth it: triage is instant, works fully offline, and cannot corrupt server
truth, because the two were never allowed to mix.

## See also

- [Store reference](../reference/store.md#mutation-queue) — the API
- [SyncEngine reference](../reference/syncengine.md#mutationflusher) — the flusher
- [local-first-sync.md](local-first-sync.md) — the read path this composes over
- [Outbox reference](../reference/outbox.md) — the same durability problem where idempotence is *not* available
