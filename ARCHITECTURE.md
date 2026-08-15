# Architecture

How Hudson is put together, and why. This is the map; the
[reference docs](docs/reference/) are the territory.

## The shape of the thing

Hudson is a local-first mail client with no server component. There are
exactly two network peers: Google (Gmail API + OAuth) and, only when a user
explicitly asks for it, an LLM provider they configured with their own key.
Everything else is a SQLite file on the user's disk.

```
   ┌─────────────┐          ┌──────────────┐
   │  hudson CLI │          │  HudsonApp   │      two front ends,
   │ (HudsonCLI) │          │  (HudsonUI)  │      one mailbox
   └──────┬──────┘          └──────┬───────┘
          │                        │
          └───────────┬────────────┘
                      ▼
        ┌───────────────────────────┐
        │          Store            │   SQLite (GRDB) — the single
        │  ~/Library/Application    │   source of truth for reads.
        │  Support/Hudson/          │   Nothing renders from network
        │  hudson.sqlite            │   responses; everything renders
        └─────────────┬─────────────┘   from here.
                      ▲
        ┌─────────────┴─────────────┐
        │  SyncEngine  │   Outbox   │   the only writers that talk to
        └─────────────┬─────────────┘   the network
                      ▼
                 ┌─────────┐
                 │ GmailKit│ ──────────────► Gmail API
                 └─────────┘

        ┌─────────┐
        │  AIKit  │ ──────────────────────► LLM provider
        └─────────┘   (only on an explicit user action; see below)
```

Read the layering as a rule: **the UI never awaits the network to show you
something.** Opening the app, scrolling the inbox, opening a thread, and
triaging all resolve against SQLite. Network work happens on a background
loop and lands in SQLite, which the UI is observing.

## The four flows

Everything Hudson does is one of four flows. Each has a dedicated doc.

### 1. Mail comes in (read path)

[→ local-first-sync.md](docs/explanation/local-first-sync.md)

```
Gmail ──► SyncEngine.syncOnce()
             │
             ├─ ensureCursor      record profile.historyId BEFORE listing,
             │                    so nothing that changes mid-backfill is lost
             ├─ pollHistory       incremental: apply history events, advance
             │                    the cursor ONCE after the last page
             ├─ backfill          paginate messages.list bounded to a 90-day
             │                    window; one commit per page
             └─ hydrateBodies     fetch full bodies newest-first, sanitize,
                                  store
                    │
                    ▼
              Store (messages, message_bodies, message_labels,
                     thread_rollup, fts_messages)
                    │
                    ▼
              GRDB ValueObservation ──► InboxModel / ThreadModel ──► SwiftUI
```

Two properties make this work. **The cursor is committed once per poll, not
per page** — Gmail reports the current mailbox `historyId` on every page, so a
per-page commit would jump the cursor to its final value on page one and a
crash would silently lose pages two onward. And **writes are version-guarded**
on `history_id`, so re-applying a stale snapshot is a no-op — which is what
makes "when in doubt, re-list" a safe recovery strategy rather than a
data-loss risk.

### 2. Triage goes out (write path)

[→ optimistic-mutations.md](docs/explanation/optimistic-mutations.md)

```
user presses `e`
      │
      ▼
Store.enqueueMutation()          canonical tables UNTOUCHED. One row into
      │                          mutation_queue + a rollup recompute, in one
      │                          transaction. The thread leaves the inbox
      │                          list immediately.
      ▼
MutationFlusher.flushOnce()      background: send to Gmail, record the
      │                          returned historyId as the retirement gate
      ▼
retireConfirmedMutations()       drop the overlay only once the account's
                                 history cursor has reached that historyId —
                                 i.e. once canonical truth has caught up
```

The overlay is retired on *echo*, not on HTTP 2xx. Retiring early would drop
the local delta before the canonical write echoed back, and the row would
visibly flicker back to its old state.

### 3. Mail goes out (send path)

[→ outbox.md](docs/reference/outbox.md)

Gmail's send API has no idempotency token, so deduplication is Hudson's job.
The protocol is three moves:

1. **Mint the `Message-ID` at enqueue** and persist it on the job row *and*
   bake it into the MIME. One identifier, both places, by construction.
2. **Commit `in_flight` before the wire.** Any job the network call might have
   delivered is already durably `in_flight` — never still `pending`, where a
   naive retry would resend it.
3. **On restart, probe — never blind-resend.** Search Sent for the job's
   `Message-ID`. A hit means delivered. A *miss is not proof of
   non-delivery* (Gmail's search index lags), so the job stays `in_flight` and
   is re-probed next pass. This is the whole reason the subsystem exists.

### 4. AI runs (egress path)

[→ ai-privacy-model.md](docs/explanation/ai-privacy-model.md)

```
explicit user action
      │
      ▼
Invocation.userInvoked(.summarize)     private init — nothing else can
      │                                mint one of these
      ▼
EgressGuard.run(request, for:)         checks ai_config.opt_in, fail-closed
      │
      ▼
LLMProvider.stream()                   the ONLY call site in the codebase
```

Two independent gates, one at compile time and one at run time. A background
task cannot fabricate an `Invocation`, and a feature the user never opted in
to throws before any socket opens.

## Why SQLite is the seam

Putting a real database between the network and the UI buys three things that
are otherwise hard:

- **Speed that survives a bad network.** The inbox list is one index-backed
  query over a denormalized `thread_rollup` table — no joins, no aggregation
  at read time. Search is an FTS5 `MATCH`. Neither depends on Gmail being
  reachable or fast.
- **Two front ends for free.** The CLI and the app are peers over the same
  file. Anything the CLI can do, the app can do, because neither owns state
  the other lacks.
- **Crash safety as a schema property.** `mutation_queue` and `send_jobs` are
  durable queues with explicit state machines. A kill -9 mid-send is a
  recoverable state, not a lost message.

The cost is that every derived table (`thread_rollup`, `fts_messages`,
`message_seq`) has to be maintained incrementally and correctly, forever. That
maintenance is why `Store` is the largest library target.

## Concurrency model

Swift 6 strict concurrency, enforced by the compiler.

| Kind of state | Model | Examples |
|---|---|---|
| Network-driven shared state | `actor` | `SyncEngine`, `MutationFlusher`, `SendService`, `QuotaBucket`, `EgressGuard`, `AccountSession` |
| UI state | `@MainActor @Observable` | `AppModel` and every child view model |
| Database | `async` methods on `HudsonDatabase` | all of `Store` |
| Values crossing boundaries | `Sendable` structs | `MessageSnapshot`, `ThreadRow`, `SendJob`, … |

**Actors are re-entrant.** An actor method that awaits mid-pass can be
re-entered by a second call, so every multi-step network pass carries an
explicit single-flight guard (`passInFlight`, `flushInFlight`). Actor
isolation alone is not enough, and assuming otherwise is the most likely way
to introduce a duplicate-send or double-flush bug here.

## Quota discipline

Google allows 6,000 quota units/minute/user. Hudson self-caps at 5,500 so a
second device or the Gmail app itself cannot push the account over.
`QuotaBucket` is a rolling-minute limiter with **two priority lanes**:
`.interactive` (a person waiting on a star/archive/send) is admitted against
the full budget; `.background` (polling, the multi-hour backfill) is admitted
only up to a reserved sub-budget. Within a lane, service is strict FIFO by a
single drain task, so an expensive acquirer (`messages.send`, 100 units) is
never starved by cheaper traffic queued behind it.

This is why a foreground archive stays instant while a fresh account is
backfilling 2,700 messages.

## Trust boundaries

Mail content is hostile input. Three boundaries exist to keep it that way:

- **`Sanitizer`** (`Store`) is the only path from a message body to the
  terminal or the FTS index. `SanitizedBody` has no public initializer, so
  untrusted content cannot reach either without passing through it. The
  sanitizer also inventories `cid:` and remote URL references so the renderer
  can block remote loads.
- **`Sanitizer.terminalSafe`** wraps anything a CLI command prints — sender
  names, subjects, label names are all attacker-influenced text.
- **`EgressGuard`** is the boundary in the other direction: the only place
  mail content can leave the machine.

## What is deliberately absent

- **No server.** There is nothing to run, nothing to trust, nothing to breach.
- **No analytics, no telemetry, no crash reporting.**
- **No background AI.** No summarize-on-scroll, no ambient classification.
- **No auto-update.** New versions are downloaded from the site.
- **No Intel build.** Apple silicon, macOS 15+.

## Further reading

- [The foundation spec](docs/superpowers/specs/2026-08-10-hudson-foundation-design.md) — the source of truth for intent, and what `§4.2`-style references point at
- [Milestone plans](docs/superpowers/plans/) — `M1`–`M7`, `U1`, `U2`, `D1`
- [docs/README.md](docs/README.md) — the full documentation index
