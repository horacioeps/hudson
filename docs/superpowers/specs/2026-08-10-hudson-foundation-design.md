# Hudson — Foundation System Design

**Date:** 2026-08-10
**Status:** Draft — under engineering review
**Scope:** The headless core ("foundation") of Hudson. UI is designed externally (see `docs/design/ui-design-brief.md`) and specified separately once designs exist.

## 1. Product context

Hudson is a free, open-source, Mac-native Gmail client with Superhuman-class speed and AI features powered by user-supplied API keys. No hosted backend, no subscription, no telemetry.

Decisions locked during brainstorming:

- **Gmail only.** Gmail REST API; no IMAP, no Microsoft Graph in v1.
- **BYO Google OAuth client.** Each user creates their own free Google Cloud OAuth client (guided setup). Hudson never operates a shared, CASA-verified OAuth app, so it stays free to run.
- **Speed-first identity.** Keyboard-driven triage is the product; AI is layered on top.
- **v1 feature bar:** core (sync / read / triage / search / compose) + command palette + split inbox + snooze & send-later + AI trio (summarize, draft-in-voice, ask-inbox).
- **Foundation-first build.** Headless Swift package + CLI harness now; thin SwiftUI shell later, built to the external designer's spec.

**Non-goals for v1:** calendar, read statuses/tracking, team features, snippets, multi-provider email, iOS, embeddings-based retrieval.

## 2. Architecture overview

One Swift package, `HudsonCore` (Swift 6 language mode, strict concurrency, macOS 15+):

```
┌─────────────────────────── hudson-cli (dev harness) ──────────────────────────┐
│                                                                               │
│  ┌──────────┐   ┌────────────────── SyncEngine (actor) ─────────────────┐     │
│  │  AIKit   │   │  backfill · incremental sync · mutation queue flush   │     │
│  └────┬─────┘   └───────┬───────────────────────────────┬───────────────┘     │
│       │                 │                               │                     │
│       ▼                 ▼                               ▼                     │
│  ┌──────────┐   ┌──────────────┐               ┌──────────────┐               │
│  │ LLM      │   │   GmailKit   │               │    Store     │               │
│  │ providers│   │ (REST+OAuth) │               │ (GRDB+FTS5)  │               │
│  └──────────┘   └──────────────┘               └──────┬───────┘               │
│                                                       │                       │
│                 ┌──────────────┐                      │                       │
│                 │    Outbox    │──────────────────────┘                       │
│                 │ (MIME, send, │  (reads drafts/jobs, writes results)         │
│                 │  scheduling) │                                              │
│                 └──────────────┘                                              │
└───────────────────────────────────────────────────────────────────────────────┘
```

Targets and dependency rules:

- **`GmailKit`** — typed Gmail REST client + OAuth. Knows nothing about persistence.
- **`Store`** — GRDB/SQLite persistence + FTS5 search. Knows nothing about the network.
- **`SyncEngine`** — the only module that composes GmailKit and Store.
- **`Outbox`** — MIME building, send, send-later, snooze scheduling. Uses GmailKit + Store.
- **`AIKit`** — LLM provider abstraction + email AI features. Uses Store (retrieval) and its own providers. Never touches GmailKit.
- **`hudson-cli`** — executable exercising every public API (`hudson auth`, `sync`, `list`, `show`, `archive`, `search`, `send`, `snooze`, `summarize`, `ask`). This is the verification surface until the UI exists.

The future Mac app is a thin SwiftUI shell over the same public APIs; nothing in HudsonCore imports UI frameworks.

## 3. Store (persistence & search)

**GRDB over SwiftData/Core Data.** Reasons: FTS5 full-text search, predictable performance at 100k+ messages, background-thread writes, explicit migrations, plain SQL when needed.

Schema v1 (tables, abbreviated):

- `accounts` — id, email, oauth client id, history cursor, sync state
- `threads` — id (Gmail thread id), account_id, snippet, last_message_at, aggregates (unread count, participants)
- `messages` — id (Gmail message id), thread_id, headers (from/to/cc/subject/date), snippet, label cache, internal_date
- `message_bodies` — message_id, html, plain_text (fetched lazily; prefetch window default 90 days)
- `labels`, `message_labels` — Gmail labels + membership
- `attachments` — metadata rows; blobs content-addressed on disk under `Application Support/Hudson/attachments/`
- `mutation_queue` — durable pending local ops (see §5)
- `scheduled_jobs` — snooze wakes and send-later sends (see §7)
- `ai_artifacts` — cached summaries, the voice profile (see §8)
- `fts_messages` — FTS5 external-content table over subject, body text, participants

Conventions: Gmail ids as TEXT primary keys, account-scoped. All writes through GRDB's single writer queue; reads via snapshots and `ValueObservation` (which later gives the UI reactive queries for free).

## 4. SyncEngine

Three invariants:

1. **Local mutations are never lost.** Enqueued durably before anything else happens.
2. **The store converges to server state** (modulo pending local ops).
3. **Reads never block on the network.** The UI/CLI reads SQLite only.

**Initial backfill:** `messages.list` newest-first (metadata format), hydrate headers via batched `messages.get`; full bodies fetched for the prefetch window, older bodies on demand. Record `profile.historyId` *before* starting so the subsequent incremental sync covers anything that changed mid-backfill. Backfill continues in the background with quota-aware pacing until the mailbox is fully indexed.

**Incremental sync:** poll `history.list` from the stored cursor (cheap — 2 quota units) on an adaptive interval (~15 s active, ~120 s idle). Apply `messageAdded` / `messageDeleted` / `labelsAdded` / `labelsRemoved`. Push notifications via Cloud Pub/Sub are *possible* later precisely because BYO OAuth means the user owns a GCP project — but polling ships first.

**History expiry:** `history.list` returns 404 when the cursor is too old → full reconciliation: re-list all ids, diff against local, fetch missing, tombstone ghosts. This path gets first-class tests, not an afterthought.

**Quota discipline:** client-side token bucket well under Gmail's per-user rate limit (~250 quota units/user/sec); batched gets capped at 50/batch; exponential backoff honoring `Retry-After` on 429/403 rate responses.

## 5. Mutation queue (writes)

Every user action (archive, star, read/unread, label, trash, snooze, send) becomes:

1. One transaction: insert `mutation_queue` row **and** apply the change optimistically to local tables.
2. A flusher (part of SyncEngine) drains the queue FIFO per account with retry/backoff. Ops are idempotent (label add/remove are set operations; sends carry a client token — see §7).
3. Terminal failure (non-rate-limit 4xx): revert the optimistic apply, surface the error.

**Conflict policy:** server wins, *except* where a local mutation is pending — incoming history events that contradict a pending op are deferred until the op flushes or fails.

## 6. Auth (BYO OAuth)

- Guided setup (CLI wizard now, designed onboarding later): create GCP project → enable Gmail API → configure OAuth consent screen → create a **Desktop app** OAuth client → paste the client ID into Hudson.
- Authorization Code + PKCE via the system browser with a `127.0.0.1` loopback redirect. Tokens in the Keychain (per-account generic password items). Silent refresh; refresh failure surfaces one `needsReauth` account state.
- **Single scope: `gmail.modify`** — covers read, label mutation, and send; excludes only permanent deletion (we use Trash, so that's fine). One scope keeps the consent screen setup simple.
- **Known risk (flagged for review):** Google issues 7-day refresh tokens to OAuth consent screens in *Testing* status for external user types. Google Workspace users can mark the app *Internal* (no expiry, no verification). What consumer @gmail.com users should do (re-auth weekly? publish-unverified caveats?) needs verification during implementation.
- LLM API keys also live in the Keychain, never in config files.

## 7. Outbox (send, send-later, snooze)

- **MIME builder:** RFC 5322 messages — `text/plain` + `text/html` alternative, quoted history, `In-Reply-To`/`References` set from the thread, attachments as `multipart/mixed`. Sent via `messages.send` with the Gmail `threadId` so threading is correct. Golden-file tests.
- **Send-later:** draft stored locally + `scheduled_jobs(kind: send, due_at)`. Not a Gmail draft — Gmail drafts can't schedule without the web UI.
- **Snooze:** remove `INBOX`, add a `Hudson/Snoozed` label (visible/recoverable from other clients), plus `scheduled_jobs(kind: unsnooze, due_at)` which re-adds `INBOX` and bumps the thread.
- **Scheduler:** an actor that fires due jobs while the app runs and catches up missed jobs at launch. At-least-once with idempotent effects.
- **Honest limitation:** client-only scheduling means a sleeping Mac delays snooze wakes and scheduled sends until next wake/launch. Documented, not hidden. (A serverless design cannot do better; Superhuman uses their servers for this.)

## 8. AIKit

- **`LLMProvider` protocol:** streaming chat with system prompt + messages. Two implementations: `AnthropicProvider` (Messages API) and `OpenAICompatProvider` (base-URL configurable → OpenAI, OpenRouter, Ollama, LM Studio, i.e. local models work out of the box). Keys from Keychain; per-feature model selection with sensible defaults.
- **Summarize(thread):** cached in `ai_artifacts` keyed by (thread id, last message id).
- **Draft(reply | new, instruction):** a *voice profile* — a distilled style card generated from the user's recent sent mail, cached and refreshed periodically — plus thread context plus the instruction.
- **AskInbox(question):** FTS5 + recency/sender heuristics retrieve top-k messages → context-stuffed prompt → answer with message-id citations the UI can open. No embeddings in v1.
- **Privacy stance:** mail content leaves the machine only to the user's configured provider, only on explicit invocation. No telemetry, ever.

## 9. Error handling

- Typed `GmailError`: `auth`, `rateLimited(retryAfter)`, `network`, `server`, `invalidRequest`.
- Auth failures collapse into one `needsReauth` state per account — never silent, never data-lossy.
- The mutation queue is crash-safe by construction (SQLite transaction covers enqueue + optimistic apply).
- Scheduler jobs are at-least-once; all effects idempotent.
- Sync applies history events transactionally; a crash mid-application resumes from the stored cursor.

## 10. Testing strategy

TDD throughout (superpowers test-driven-development).

- **Unit:** MIME builder golden files; store migrations; mutation queue state machine; snooze/send-later scheduling logic with a controllable clock.
- **GmailKit:** recorded-fixture tests; transport mocked at `URLProtocol` level.
- **SyncEngine:** in-process mock Gmail server with fault injection — expired historyId, 429s, partial pages, network drops mid-batch. Property-style test: any interleaving of local ops and server events converges with no lost mutations.
- **Integration (opt-in):** `HUDSON_TEST_ACCOUNT` env → real throwaway Gmail account exercised end-to-end in CI-optional runs.
- **CLI** is the manual verification surface for every milestone.

## 11. Foundation milestones

Each gets its own implementation plan (superpowers writing-plans):

- **M1 — Auth + GmailKit:** OAuth flow, token store, typed client. CLI: `auth`, `profile`.
- **M2 — Store + backfill:** schema, migrations, initial sync. CLI: `sync`, `list`, `show`.
- **M3 — Mutations + incremental sync:** queue, flusher, history polling. CLI: `archive`, `star`, `read`.
- **M4 — Search:** FTS5 indexing + query. CLI: `search`.
- **M5 — Send:** MIME builder, send, reply threading. CLI: `send`, `reply`.
- **M6 — Scheduling:** snooze, send-later, catch-up. CLI: `snooze`, `later`.
- **M7 — AIKit:** providers, summarize, draft-in-voice, ask-inbox. CLI: `summarize`, `draft`, `ask`.

**Foundation exit criteria:** daily-drivable from the CLI against a real inbox; all §4/§5 invariants covered by fault-injection tests. UI shell milestones begin when the designer's deliverables land.

## 12. Risks & open questions

1. **7-day refresh tokens** for consumer accounts on Testing-status consent screens (§6) — verify current Google policy and pick a mitigation.
2. **Backfill at scale** — 100k+ message mailboxes: pacing, resumability, disk footprint.
3. **HTML email rendering** (UI phase) — sandboxed WKWebView, remote-image blocking; the Store must retain raw HTML for it.
4. **Ask-inbox retrieval quality** with pure FTS5 — acceptable for v1; embeddings are a v2 question.
5. **Distribution** (UI phase) — notarized DMG via GitHub Releases, Sparkle for updates.
