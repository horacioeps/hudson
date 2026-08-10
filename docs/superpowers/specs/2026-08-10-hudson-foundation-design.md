# Hudson — Foundation System Design

**Date:** 2026-08-10
**Status:** v2 — revised after multi-lens engineering review (11-agent ultracode review: eng-manager, sync-correctness, Gmail API fact-check, Swift/macOS, security; all findings adversarially verified)
**Scope:** The headless core ("foundation") of Hudson. UI is designed externally (see `docs/design/ui-design-brief.md`) and specified separately once designs exist.

## 1. Product context

Hudson is a free, open-source, Mac-native Gmail client with Superhuman-class speed and AI features powered by user-supplied API keys. No hosted backend, no subscription, no telemetry.

Decisions locked during brainstorming:

- **Gmail only.** Gmail REST API; no IMAP, no Microsoft Graph in v1.
- **BYO Google OAuth client.** Each user creates their own free Google Cloud OAuth client (guided setup). Hudson never operates a shared, CASA-verified OAuth app, so it stays free to run.
- **Speed-first identity.** Keyboard-driven triage is the product; AI is layered on top.
- **v1 feature bar:** core (sync / read / triage / search / compose) + command palette + split inbox + snooze & send-later + AI trio (summarize, draft-in-voice, ask-inbox).
- **Foundation-first build.** Headless Swift package + CLI harness now; thin SwiftUI shell later, built to the external designer's spec.

**Non-goals for v1:** calendar, read statuses/tracking, team features, snippets, multi-provider email, iOS, embeddings-based retrieval, encrypted-at-rest store (see §3.3).

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
- **`Store`** — GRDB/SQLite persistence + FTS5 search + query APIs (including split-inbox queries, §3.4). Knows nothing about the network.
- **`SyncEngine`** — the only module that composes GmailKit and Store.
- **`Outbox`** — MIME building, send, send-later, snooze scheduling. Uses GmailKit + Store.
- **`AIKit`** — LLM provider abstraction + email AI features. Uses Store (retrieval) and its own providers. Never touches GmailKit.
- **`hudson-cli`** — executable exercising every public API (`hudson auth`, `sync`, `list`, `inbox --split`, `show`, `archive`, `search`, `send`, `snooze`, `summarize`, `ask`, `diagnose`). This is the verification surface until the UI exists.

The future Mac app is a thin SwiftUI shell over the same public APIs; nothing in HudsonCore imports UI frameworks. Anything a v1 feature needs (split inbox included) therefore lives in HudsonCore, not the shell.

## 3. Store (persistence & search)

**GRDB over SwiftData/Core Data.** Reasons: FTS5 full-text search, predictable performance at 100k+ messages, background-thread writes, explicit migrations, plain SQL when needed.

### 3.1 Schema v1 (tables, abbreviated)

- `accounts` — id, email, OAuth client id, history cursor, sync state
- `threads` — id (Gmail thread id), account_id, snippet, last_message_at, aggregates (unread count, participants)
- `messages` — id (Gmail message id), thread_id, headers (from/to/cc/subject/date), snippet, label cache, internal_date, **history_id** (the per-message `historyId` Gmail returns on every Message resource — the version guard for all snapshot writes, §4.2)
- `message_bodies` — message_id, raw_html (opaque bytes, never interpreted by the foundation), plain_text (derived, §3.5), **sanitizer_version**, cid_attachment_map, remote_resource_urls
- `labels`, `message_labels` — Gmail labels + membership (including `CATEGORY_*` system labels, persisted like any other label — split inbox depends on them)
- `tombstones` — message ids deleted server-side or trashed locally; consumed by backfill so late pages cannot resurrect deleted messages
- `attachments` — metadata rows; blobs content-addressed on disk under `Application Support/Hudson/attachments/`, refcounted
- `mutation_queue` — durable pending local ops (§5)
- `scheduled_jobs` — snooze wakes and send-later sends (§7), with per-job state machine columns
- `split_rules` — account-scoped, ordered predicates (sender / domain / list-id / `CATEGORY_*` label) mapping to a named split (§3.4)
- `ai_artifacts` — cached summaries, the voice profile (§8)
- `fts_messages` — FTS5 index (§3.2)

Conventions: Gmail ids as TEXT primary keys, account-scoped. All writes through GRDB's single writer queue; reads via snapshots and `ValueObservation` (which later gives the UI reactive queries for free).

### 3.2 Full-text search index

`fts_messages` is a **plain FTS5 table maintained explicitly by the Store** (not external-content: our indexed text spans `messages` and `message_bodies`, and FTS5's `content=` option names a single table/view while leaving consistency entirely to the app — a joined view plus lazily-mutating bodies makes the external-content contract easy to violate silently).

Maintenance rules, always inside the same GRDB write transaction as the source-row change:

- Message insert → FTS stub row (subject, participants, snippet).
- Body arrival / re-derivation → FTS5 delete-then-reinsert for that rowid with body text included.
- Message purge → FTS row delete.

`hudson search --rebuild-index` exposes a full rebuild; the test suite runs FTS5's `integrity-check` so index/content divergence fails loudly.

### 3.3 At-rest data & threat model

- **FileVault is the at-rest protection.** Hudson checks at first run and warns visibly if it is off.
- The Hudson data directory is **excluded from Time Machine by default** (backup-exclusion attribute; documented setting to re-include). Safe because Gmail is the source of truth and the store is fully re-syncable.
- **Purge-on-delete:** deleting a message removes its `message_bodies` row, FTS entries, `ai_artifacts`, and attachment blobs (refcount-decremented for shared blobs).
- SQLCipher / encrypted store is **explicitly out of scope for v1** — a deliberate decision, revisitable.

### 3.4 Split inbox (v1 feature — lives in the foundation)

`split_rules` + a per-split query API in Store (`inboxThreads(split:)`), exercised by `hudson inbox --split <name>`. Category-based splits (Important / Promotions / Updates…) work with zero setup because `CATEGORY_*` labels already flow through `messages.get` and history events — a sync test asserts they persist. User rules are ordered predicates evaluated locally. Built in M4 alongside search (both are query-layer concerns).

### 3.5 Untrusted-content pipeline

Mail content is hostile input. Raw HTML is stored as opaque bytes and never interpreted by the foundation. One sanitizer/extractor produces the plain text used for **both** FTS indexing and all CLI display; `sanitizer_version` on each body row lets future sanitizer fixes trigger re-derivation. The extractor also records the `cid:`→attachment map and the remote-resource URL list, so the future WKWebView renderer can block remote loads without re-parsing trust decisions.

**CLI display rule:** every message-derived string printed to the terminal (subject, snippet, body text, sender name) is stripped of C0/C1 control characters and ANSI/OSC escape sequences — terminal escape injection is reachable from the first `hudson list` otherwise.

## 4. SyncEngine

Three invariants:

1. **Local mutations are never lost.** Enqueued durably before anything else happens.
2. **The store converges to server state** (modulo pending local ops, which are a rebased overlay — §5).
3. **Reads never block on the network.** The UI/CLI reads SQLite only.

### 4.1 Backfill and incremental sync run concurrently

- Record `profile.historyId` **before** backfill starts, and start the incremental poll loop **immediately** — it runs alongside backfill, continuously advancing the cursor so it never ages more than one poll interval (Gmail's history retention is typically about a week but "may be significantly less"; a cross-session backfill on a sleeping laptop has unbounded wall-clock duration, so "catch up after backfill" would routinely 404).
- Backfill: `messages.list` newest-first, hydrate via batched `messages.get`; full bodies for the prefetch window (default 90 days) first, then **background body hydration continues, quota-paced and resumable, until every body is stored and FTS-indexed** (this resolves search coverage — §4.4).
- History events referencing ids backfill hasn't reached yet: `messageAdded` → insert stub row, hydrate via the normal batched-get path; `labelsAdded/Removed` on an unknown id → hydrate-then-apply (dropping is also safe under the version guard, since the eventual backfill get is newer); `messageDeleted` → write a tombstone that backfill consumes.

### 4.2 Versioned writes (the anti-clobber rule)

Every snapshot write — backfill hydration, on-demand `messages.get`, reconciliation — carries the message's `historyId` and applies **only if** `snapshot.historyId >=` the stored `history_id`; otherwise the stale snapshot is discarded. History-event applies bump the stored `history_id`. Tombstoned ids reject snapshot inserts. Without this, a `messages.get` response fetched moments before a phone-side archive would overwrite the already-applied `labelsRemoved` event after the cursor advanced — permanent divergence.

### 4.3 Incremental sync & reconciliation

- Poll `history.list` from the stored cursor (2 quota units) on an adaptive interval (~15 s active, ~120 s idle). Apply `messageAdded` / `messageDeleted` / `labelsAdded` / `labelsRemoved` in order. Cloud Pub/Sub push is possible later (BYO OAuth means the user owns a GCP project), but polling ships first.
- **All pages of one poll are fetched first, then applied and the cursor advanced inside a single GRDB write transaction — no `await` between apply and cursor update.** Crash mid-poll resumes cleanly from the stored cursor.
- **History expiry (404) → full reconciliation, Google's documented procedure:** re-list all ids; batched `messages.get` with `format=minimal` (labelIds + historyId, cheap payload) for **every** id — not just missing ones, because `messages.list` alone returns only id/threadId and an id-set diff is blind to every read/archive/star that happened during the gap; apply label diffs through the §4.2 version guard (unchanged messages short-circuit); tombstone ghosts; record the newest message's `historyId` as the new cursor.

### 4.4 Search coverage during hydration

Until body hydration completes, body-text search has a blind spot outside the hydrated window. `hudson search` therefore transparently merges local FTS hits with a server-side `users.messages.list?q=` call when the network allows, flagging server-sourced results; the CLI surfaces hydration progress (`hudson sync --status`). Ask-inbox (§8) inherits the same caveat and surfaces the same progress.

### 4.5 Quota discipline (May 2026 limits)

Google's current limits — which apply to **every** Hudson user, since BYO OAuth means each user's GCP project is brand-new — are **6,000 quota units/min/user** (per-minute enforcement) with per-method costs: `messages.get` = 20, `messages.list` = 5, `messages.send` = 100, `history.list` = 2, `getProfile` = 1. (Projects created before Nov 2025 kept the old ~250 units/sec regime; bucket parameters are configurable for them.)

- Client-side token bucket capped at ~5,500 units per rolling minute per account; per-method cost accounting; exponential backoff honoring `Retry-After` on 429/403.
- **Backfill budget is real:** ~275 `messages.get`/min sustained → a 100k-message mailbox needs ~6 hours of API time. Backfill is therefore multi-session, resumable, and interruption-safe by design, with headers-first hydration so the mailbox is *usable* long before it is *complete*.
- Batched HTTP requests (≤50/batch) are a latency optimization only — each inner call is charged full quota.

### 4.6 Concurrency discipline (actors are re-entrant)

Swift actors are re-entrant at every `await` (SE-0306), and every Gmail call and async GRDB call suspends — actor isolation alone does not bound interleavings. Therefore:

- **Single-flight rule:** at most one sync pass (backfill page, history poll, or reconciliation) and one flusher drain in flight per account, enforced by an explicit state machine / job loop fed by an `AsyncStream`; timer ticks arriving mid-pass coalesce.
- Any state that lives across an `await` (cursors, overlay, job progress) is durable in SQLite, never actor memory.
- All Store access from actor code uses GRDB's async APIs; synchronous `DatabaseQueue.write/read` from actor-isolated code is banned (it blocks a cooperative-pool thread) — enforced by convention and lint.

## 5. Mutation queue (writes)

Every triage action (archive, star, read/unread, label, trash, snooze) becomes:

1. One transaction: insert `mutation_queue` row **and** apply the change optimistically.
2. A flusher (SyncEngine) drains the queue FIFO per account with retry/backoff. Label ops are idempotent set operations; **sends are deduplicated by the persisted Message-ID protocol (§7.3)** — Gmail's API has no idempotency token, so dedup is our job.
3. **Terminal failure (non-rate-limit 4xx):** delete the queue row (dropping its overlay entry), then re-fetch the affected message ids via batched `messages.get format=minimal` and write the fresh snapshots through the §4.2 version guard — local state converges to actual server truth rather than to an inverse-op guess (by failure time, minutes of server events may have landed on top; an "undo" would clobber them). Surface the error to the user.

**Conflict model — rebase, not deferral:** history events always apply immediately, in order, to the canonical server-state tables, and the cursor always advances. Effective local state = server state **plus** the pending queue's label deltas re-applied as an overlay (keyed by message id + label id; all in-scope ops are commutative set operations). An overlay entry is dropped when its op's flush returns 2xx (not by matching echo history events — Gmail events carry no origin tag) or on terminal failure, letting server state show through. This eliminates head-of-line blocking, the crash-window loss of deferred events, and cursor stalls that the earlier "defer contradicting events" design implied.

**M3 Implementation:** The read-time overlay, cursor-gated retirement (dropping stale queued mutations when the cursor advances past them), and mutation flusher with dedup are implemented as described in the architecture doc (docs/superpowers/design/2026-08-10-speed-ai-architecture.md, M3 section).

## 6. Auth (BYO OAuth)

### 6.1 Guided setup

CLI wizard now, designed onboarding later: create GCP project → enable Gmail API → configure the OAuth consent screen (**External**) → **publish the app to "In production" immediately** (unverified; no test users) → create a **Desktop app** OAuth client → paste **both the Client ID and the Client Secret** into Hudson.

- **Publishing status is the 7-day-token fix.** Google's 7-day refresh-token expiry is a property of *Testing* status, not of verification. Publishing to production (unverified) yields normal long-lived refresh tokens; the user sees a one-time "Google hasn't verified this app → Advanced → Continue" interstitial, which the wizard explains with a screenshot. The 100-user cap on unverified restricted-scope apps is moot — each BYO project has exactly one user. Workspace users may instead mark the app **Internal** (no interstitial, no expiry). The wizard has the user explicitly confirm the published status before finishing — Google exposes no API for reading consent-screen publishing status, so self-attestation plus the runtime heuristic is the implementable form — and Hudson treats `invalid_grant` within ~7 days of consent as a "your OAuth app is probably still in Testing — publish it" diagnostic.
- **The client secret is required** at the token endpoint for Desktop-app clients even with PKCE; per Google's installed-app docs it is "not treated as a secret" for this client type, so pasting it is safe. It still lives in the Keychain, and **no Google credentials may ever appear in the repo or recorded fixtures — enforced by a CI secret-scan**.
- Re-auth is rare but real even in production status (password change, ~6 months disuse, per-client live-token cap): the `needsReauth` state stays.

### 6.2 Authorization flow

Authorization Code + PKCE in the system browser; loopback listener bound to `127.0.0.1` **only**, OS-assigned ephemeral port, `redirect_uri` built with that port; `state` verified; a small local success/failure page closes the loop. Known caveat, documented for support: Safari's HTTPS-Only mode can refuse the `http://127.0.0.1` callback — remediation guidance in the setup docs. (UI phase note: a sandboxed app needs `com.apple.security.network.server` for the listener, or an auth-helper/XPC split — decided then.)

**Scope: single `gmail.modify`** — covers read, label mutation, and send; excludes only permanent deletion (we use Trash). One scope keeps consent setup simple.

### 6.3 Token storage mechanics

All secrets (OAuth tokens, client secret, LLM keys) go through a `TokenStore` protocol (integration tests inject an in-memory store; the real Keychain is never touched by CI).

- **Now (CLI, dev):** file-based login keychain items. `hudson-cli` is signed with a stable identity (Developer ID, or a locally created self-signed cert via `Scripts/sign-cli.sh`) so Keychain ACLs — which match signing identity, not binary hash — survive rebuilds and don't re-prompt on every `swift build`. A bare Mach-O CLI cannot carry the provisioning profile that the data-protection keychain's restricted entitlements require, so `kSecUseDataProtectionKeychain` is not available to it; accepted for the dev phase.
- **Later (signed, bundled app):** `kSecUseDataProtectionKeychain = true`, a keychain access group, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (precludes iCloud Keychain sync; `kSecAttrSynchronizable = false` as belt-and-suspenders). Either embed `hudson-cli` in the app bundle sharing the access group, or run a one-time migration from the file-based items at first app launch.

## 7. Outbox (send, send-later, snooze)

### 7.1 MIME builder

RFC 5322 messages — `text/plain` + `text/html` alternative, quoted history, attachments as `multipart/mixed`. **Threading requires all three:** Gmail `threadId` on the send call, RFC-compliant `References`/`In-Reply-To`, **and a matching Subject** — replies derive their Subject from the thread with normalized `Re: ` prefixing (tolerating existing `Re:`/localized `AW:`/`SV:` prefixes), and an edited subject deliberately starts a new thread (threadId omitted). Golden-file tests assert all three.

**Size limits:** sends go through the `/upload/gmail/v1` endpoint (multipart for small, resumable for large; 35 MB MIME cap ⇒ ~25 MB effective attachments after base64). The Outbox validates encoded size **at compose/enqueue time** — never at scheduler fire time after the user walked away.

### 7.2 Send-later = a real Gmail draft

Each scheduled message is mirrored as a Gmail draft (`drafts.create`) labeled `Hudson/SendLater` at schedule time; the scheduler fires `drafts.send` at due time and deletes the mirror on cancel. The server draft is the source of truth at fire time (it is visible and editable from other clients). This kills the silent-loss failure mode — if the Mac is lost or wiped, pending scheduled mail is findable in any Gmail client under `Hudson/SendLater` — and the draft id doubles as a server-side retry handle (a successfully sent draft ceases to exist).

### 7.3 Send dedup protocol (Gmail has no idempotency token)

- The MIME builder assigns a UUID-based RFC 5322 `Message-ID` at **enqueue** time, persisted on the job row.
- Send jobs run an explicit state machine — `pending → in_flight → sent` — with the `in_flight` transition committed to SQLite **before** the network call.
- On startup or retry of any `in_flight` job with unknown outcome: probe `users.messages.list q=rfc822msgid:<id> in:sent` first, and skip if found. A fast miss is not proof of non-delivery (search indexing lags) — ambiguous outcomes wait and re-probe rather than resend. For draft-mirrored sends, `drafts.get` 404 (draft gone) is the stronger success signal.
- §10's fault-injection suite includes the kill-between-send-and-record window.

### 7.4 Snooze

Remove `INBOX`, add `Hudson/Snoozed` (visible/recoverable from other clients), plus `scheduled_jobs(kind: unsnooze, due_at)` re-adding `INBOX` and bumping the thread.

### 7.5 Scheduler

- Computes the **next** `due_at` and arms a timer for it (no periodic tick loop). The imminent-send window is wrapped in `ProcessInfo.beginActivity(.userInitiated)` so App Nap cannot defer an actual send. (SyncEngine's poll loop is App Nap-*tolerant* by design — drift is acceptable for polling, never for sends.)
- Catch-up pass runs at launch **and** on `NSWorkspace.didWakeNotification` **and** on significant clock change — the common case is a long-running app whose Mac slept overnight, where no launch ever happens. Exposed as `Scheduler.catchUp()` for the future shell too.
- At-least-once with idempotent/deduplicated effects (§7.3).
- **Honest limitation:** with the Mac fully asleep or off, jobs fire at next wake — inherent to a serverless design; documented. Send-later's draft mirror (§7.2) is the recovery story.

## 8. AIKit

- **`LLMProvider` protocol:** streaming chat with system prompt + messages. Two implementations: `AnthropicProvider` (Messages API) and `OpenAICompatProvider` (base-URL configurable → OpenAI, OpenRouter, Ollama, LM Studio — local models work out of the box). Keys from Keychain; per-feature model selection with sensible defaults.
- **Summarize(thread):** cached in `ai_artifacts` keyed by (thread id, last message id).
- **Draft(reply | new, instruction):** uses a *voice profile* — a distilled style card generated from the user's sent mail. **Explicit invocation only:** the profile is generated on first use of draft-in-voice and refreshed only via a user-visible "refresh voice profile" command or a staleness check performed *during* an explicit draft invocation. No background AI egress, ever.
- **AskInbox(question):** FTS5 + recency/sender heuristics retrieve top-k messages → context-stuffed prompt → answer with message-id citations. Quality depends on body-hydration progress (§4.4), which the CLI surfaces alongside answers. No embeddings in v1.
- **Egress table** (enforced identically by CLI and future UI; opt-in state recorded in the Store):

  | Feature | What leaves the machine |
  |---|---|
  | Summarize | the one thread |
  | Draft | voice profile + current thread + instruction |
  | Ask-inbox | the question + top-k retrieved messages |

- **Privacy stance:** mail content goes only to the user's configured provider, only on explicit invocation. No telemetry, ever.

## 9. Error handling

- Typed `GmailError`: `auth`, `rateLimited(retryAfter)`, `network`, `server`, `invalidRequest`.
- Auth failures collapse into one `needsReauth` state per account — never silent, never data-lossy — with the Testing-status heuristic from §6.1.
- The mutation queue is crash-safe by construction (SQLite transaction covers enqueue + optimistic apply); all effects are idempotent or deduplicated by the persisted Message-ID probe (§7.3).
- History application is transactional per poll (§4.3); crash resumes from the stored cursor.

### 9.1 Logging & diagnostics

Structured logging via `os.Logger`, dynamic values default `.private`. Hard never-log list at every level: Authorization headers, tokens, auth codes, client secrets, message bodies/snippets/subjects, LLM prompt/response payloads. Network-layer logs carry method, endpoint path template, status code, and quota metadata only. `hudson diagnose` produces a redacted diagnostics bundle — the sanctioned artifact for GitHub issues. A test greps logs produced against recorded fixtures for token and body markers.

## 10. Testing strategy

TDD throughout (superpowers test-driven-development).

- **Unit:** MIME builder golden files (threading triple incl. Subject, size validation, oversized-message error); store migrations; mutation/send state machines; scheduler logic with a controllable clock (incl. wake and clock-change catch-up).
- **GmailKit:** recorded-fixture tests; transport mocked at `URLProtocol` level; CI secret-scan over fixtures.
- **SyncEngine:** in-process mock Gmail with fault injection — expired historyId, 429s, partial pages, network drops mid-batch, kill-between-send-and-record. Property-style test: any interleaving of local ops, history events, backfill pages, and crashes converges under the rebase/overlay model with no lost mutations — including the stuck-op-while-history-flows interleaving and the stale-snapshot race (§4.2).
- **Store:** FTS5 `integrity-check` after randomized insert/hydrate/purge sequences; sanitizer pipeline tests (control-character stripping, cid-map extraction).
- **Integration (opt-in):** `HUDSON_TEST_ACCOUNT` env → real throwaway Gmail account, in-memory TokenStore, CI-optional.
- **CLI** is the manual verification surface for every milestone.

## 11. Foundation milestones

Each gets its own implementation plan (superpowers writing-plans):

- **M1 — DONE:** OAuth wizard (publish-status verification, client ID+secret), token store + CLI signing script, typed client, quota-aware transport. CLI: `auth`, `profile`.
- **M2 — DONE:** schema, migrations, versioned writes + tombstones, sanitizer pipeline, concurrent backfill/poll skeleton. CLI: `sync`, `list`, `show`.
- **M3 — DONE:** queue, overlay model, flusher, single-flight discipline, reconciliation path. CLI: `archive`, `star`, `read`, `pending`, `undo`.
- **M4 — Query layer:** FTS5 search (+ server-merge during hydration, `--rebuild-index`) and split inbox (`split_rules`, category persistence test). CLI: `search`, `inbox --split`.
- **M5 — Send:** MIME builder, dedup state machine, send, reply threading. CLI: `send`, `reply`.
- **M6 — Scheduling:** snooze, send-later with draft mirror, wake/clock-change catch-up. CLI: `snooze`, `later`.
- **M7 — AIKit:** providers, summarize, draft-in-voice, ask-inbox. CLI: `summarize`, `draft`, `ask`.

**Foundation exit criteria:** daily-drivable from the CLI against a real inbox; all §4/§5 invariants covered by fault-injection tests. UI shell milestones begin when the designer's deliverables land.

## 12. Risks & open questions

1. **Google policy drift** — the §6.1 publish-to-production path and the May-2026 quota regime reflect current policy; both are wizard-verified at setup time but can change under us. Residual, monitored.
2. **Backfill at scale** — ~6 h of quota-paced API time per 100k messages (§4.5); mitigated by headers-first hydration and resumability, but disk footprint (bodies + attachments + FTS) needs measurement in M2.
3. **HTML email rendering** (UI phase) — sandboxed WKWebView consuming §3.5's stored raw bytes, cid-map, and remote-resource list.
4. **Ask-inbox retrieval quality** with pure FTS5 — acceptable for v1; embeddings are a v2 question.
5. **Distribution** (UI phase) — notarized DMG via GitHub Releases, Sparkle for updates; sandbox + network.server entitlement decision for the auth listener (§6.2).
