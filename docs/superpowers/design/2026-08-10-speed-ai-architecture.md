# Hudson — Speed + AI Architecture (M3→UI)

**Date:** 2026-08-10
**Source:** 9-agent ultracode design workflow (4 design dimensions — instant read path, instant write/triage, AI layer, Superhuman-parity teardown — each adversarially stress-tested against the "fastest mailbox ever" bar, then synthesized). Grounded in the built M1/M2 code; external facts (Claude 5 pricing, FTS5 behavior, SwiftUI budgets) web-verified.
**Status:** Locked technical direction. Feeds each milestone's implementation plan. Supersedes nothing in the spec; refines §4/§5/§8 and adds the performance contract.

## Performance contract (the promises behind "fastest mailbox ever")

1. **Inbox first paint < 16ms** (target < 8.3ms on 120Hz ProMotion). Bounded, index-backed `thread_rollup` query (`WHERE account_email=? AND in_inbox=1 ORDER BY last_message_at,thread_id DESC LIMIT 50`) via async ValueObservation with a skeleton placeholder — never a synchronous, unbounded, or `GROUP BY` main-thread fetch at launch.
2. **Keystroke-to-repaint for triage < 16ms**, from an in-memory `@Published` main-actor overlay applied synchronously on keypress. The card leaves the inbox in the same frame; the durable `mutation_queue` write and ValueObservation reconcile afterward. The instant visual is **never** gated on the single GRDB writer or an observation round-trip — that path is what the 6h backfill saturates.
3. **Search-as-you-type < 50ms at 200k messages** (sub-16ms typical). Debounced 30–50ms cancellable `writer.read` reads (not ValueObservation), a 2–3 char minimum, bm25 rank + `LIMIT 50`.
4. **Thread open (hydrated, within 90-day window): sanitized plain-text < 16ms** from local SQLite; the rich WKWebView render is progressive, off the critical path.
5. **Thread open (unhydrated / older than 90 days): headers+snippet < 16ms, body is network-bound** via an on-demand priority hydration lane — NOT guaranteed sub-100ms. Hudson's honest cold-start caveat.
6. **Mutation flush begins < 5ms after enqueue** (AsyncStream wakeup on a flusher loop split from the sync pass — never waits for the ~15s poll tick). A foreground modify (5u) or on-demand body get (20u) acquires quota in < 50ms even under full backfill, via a reserved interactive lane (~1,000 u/min carved from ~5,500; background gets ~4,500).
7. **Backfill perceived speed: first screenful (~50 rows) in ~2–3s** by priming the first 1–2 metadata pages into the interactive lane; mailbox usable in seconds while full 100k-message hydration runs ~6h in the background, resumable.
8. **Reactive-list refresh coalesced to ≤4/sec during backfill** (Combine `.throttle` + `.removeDuplicates` on a rollup-scoped observation). The load-bearing control is **batching backfill/history into one transaction per page** (per-message SAVEPOINT for error isolation), cutting commits ~100x at the source; throttle is cosmetic smoothing.

## AI layer (design)

AIKit is a thin, local-first feature layer composing **only Store + its own streaming LLM providers — never GmailKit** (mirrors how Runtime wires SyncEngine over HudsonDatabase). Four pillars:

1. **`LLMProvider`** — one streaming verb (system + messages → `AsyncThrowingStream` of typed events: `.textDelta` / `.thinkingDelta` / `.usage` / `.stopped`). `AnthropicProvider` (event-typed SSE) + `OpenAICompatProvider` (data-chunk SSE; covers OpenRouter/Ollama/LM Studio). `LLMHTTP` is a **genuine streaming byte seam** (`URLSession.bytes → AsyncThrowingStream<UInt8>`), NOT the buffered `HTTPTransport` — a buffered `Data` blob can't stream SSE or exercise first-token latency.
2. **`EgressGuard`** — the single internal choke point, the ONLY caller of `provider.stream`, reachable only through an `Invocation` token minted by an explicit CLI/UI action + a per-feature opt-in row. This makes spec §8's "no background AI egress, ever" a **type-level guarantee**.
3. **`ai_artifacts`** — content-addressed cache keyed `(kind, key, model, prompt_version)`; re-viewing is a <50ms local read with zero re-egress. Purge-on-delete via a provenance table `ai_artifact_sources(account_email, artifact_key, message_id)` with `ON DELETE CASCADE` FK to messages (a thread-keyed summary has no cascade path from one deleted message).
4. **`Retriever` seam** — pure FTS5/BM25 in v1; a v2 sqlite-vec RRF hybrid drops in without a feature-API rewrite.

Keys in a Keychain-backed `LLMKeyStore` (mirrors the TokenStore seam — Keychain + InMemory so CI never touches a real keychain); non-secret model/base_url config in an `ai_config` table.

**Models (config-driven via `ai_config`, never hardcoded — the Sonnet 5 intro price ends 2026-08-31):**
- **Summarize** → **Claude Haiku 4.5** (`claude-haiku-4-5`, $1/$5 per MTok, 200K) — highest-volume, latency-critical, most-cached; keyed `(thread_id, last_message_id)` so new mail forces free correct regen.
- **Draft-in-voice + Ask-inbox + voice-profile distillation** → **Claude Sonnet 5** (`claude-sonnet-5`, $3/$15; intro $2/$10 through 2026-08-31; 1M context).
- **Premium user-selectable:** Claude Opus 5 (`claude-opus-5`, $5/$25), Claude Fable 5 (`claude-fable-5`, $10/$50).

**5-series request contract (verified):** no `budget_tokens`; no `temperature`/`top_p`/`top_k` (all 400 on Opus/Sonnet/Fable 5); adaptive thinking; **streaming mandatory** (avoids HTTP timeouts); `stop_reason == "refusal"` handled gracefully (branch before reading content).

**Corrections that must not be reintroduced:**
- Prompt caching is NOT a summarize/draft cost pillar — compact prefixes never clear Sonnet 5's **1024-token** minimum cacheable prefix (512 is Opus 5). Apply caching only to ask-inbox follow-ups, breakpoint AFTER the large retrieved-context block.
- LLM output is untrusted → sanitize through `Sanitizer.terminalSafe` on a **coalesced buffer** that carries a trailing partial escape into the next chunk (per-delta sanitization lets an attacker split one CSI/OSC across deltas).
- Voice-profile `source_fingerprint` folds in the hydrated-sent-body count + a minimum-corpus threshold, so a profile distilled early over mostly-NULL sent bodies invalidates as older sent mail backfills.

**Honesty/scope:** ask-inbox is two serial hops (Haiku query-expansion, then Sonnet cited answer) → ~3.5s time-to-first-answer; expansion skipped for lexical queries, answer streamed. Auto-summarize-on-scroll is **out of scope** under no-background-egress (scroll-as-invocation would egress every thread). Ask-inbox/search always surface hydration coverage. AIKit adds its own 429 backoff (QuotaBucket doesn't cover the LLM path).

## Roadmap (M3 → UI)

### M3 — Mutations + incremental sync (instant write/triage)
**Goal:** triage feels instantaneous and never blocks reads.
- Canonical tables stay **pure server truth**; effective labels = canonical XOR pending deltas (SQL view/LEFT JOIN). New `mutation_queue` table (migration v2): label deltas keyed `(account, message_id, label_id, add/remove)`.
- **Decouple the instant visual from SQLite:** in-memory `@Published` main-actor overlay applied synchronously on keypress (0-frame); durable enqueue in background; ValueObservation reconciles when it catches up.
- `PRAGMA synchronous=NORMAL` (safe under WAL; Gmail is source of truth) + `cache_size`, `mmap_size`, `busy_timeout` via `Configuration.prepareDatabase` — foundation currently sets only `foreignKeysEnabled`, so default FULL fsync is in force and "sub-ms enqueue" is otherwise false.
- Retire an overlay entry by the **historyId** returned from `messages.modify` (returns the full Message), gated on `account.history_cursor >= H` — not by 2xx (which opens a reappear-flicker window).
- Coalesce rapid triage into `batchModify` (50u, ≤1000 msgs, 204 empty body → capture a historyId ceiling via getProfile); single `modify` (5u, returns Message) for lone archives.
- **Add `post<Body,Response>` (and void-returning) core to GmailClient** — current `get<>` is GET-only, hard-codes 200→JSONDecode, and would throw on batchModify's 204 empty body.
- **Priority lane on QuotaBucket:** `acquire(cost:, class:.interactive|.background)`; reserve ~1,000 u/min interactive; preserve within-class FIFO.
- Split the flusher from `syncOnce` (own single-flight + AsyncStream wakeup) so flush starts <5ms after enqueue.
- Batch backfill/history writes into one transaction per page (per-message SAVEPOINT).
- Terminal-failure convergence via version-guarded minimal re-fetch (never an inverse-op guess); undo = inverse-delta enqueue.
- **Biggest risk:** the perceived-speed thesis depends on the one path contending with the 6h backfill. Decouple-to-overlay + page-batching + rollup-scoped throttle must land together or the single writer serializes archive enqueues behind MB-sized raw_html writes and the UI janks during the first-impression window.

### M4 — Query layer (instant read path: rollup, search, split inbox)
**Goal:** every UI surface resolves from one index-backed, LIMIT-bounded query; zero N+1; zero query-time aggregation.
- **Materialize `thread_rollup`** (PK account_email, thread_id; last_message_at, last_message_id, subject, snippet, from_summary, message_count, unread, in_inbox, split_key, category) as the SOLE inbox-list observation surface — the built `threads` table carries only last_message_at, so a thread-grouped list can't be served without a read-time GROUP BY over ~50k groups.
- Maintain the rollup **incrementally** (insert → count+1, last_message_at=MAX, unread OR, from_summary append-dedup — all O(1)); targeted per-thread recompute ONLY for unread-clearing label events. Requires `applySnapshotInTransaction` to distinguish insert vs update.
- **M4 migration MUST run a one-time bulk build** (GROUP BY over already-backfilled messages, once, inside the migration) AND auto-run FTS `--rebuild-index` — else an install with 100k M2/M3 messages gets an empty inbox + empty search until a full resync.
- Add three indexes: `messages(account_email, thread_id, internal_date)`; `message_labels(account_email, label_id, message_id)`; `thread_rollup(account_email, in_inbox, last_message_at)` + `(account_email, split_key, last_message_at)`. Sort key `(last_message_at, thread_id)` for stable keyset pagination.
- Eliminate the N+1 label fetch in recentMessages (durable fix: unread/in_inbox/category denormalized onto the rollup).
- **FTS5:** plain (non-external-content) `fts_messages(subject, from_addr, to_addr, body, message_id UNINDEXED, thread_id UNINDEXED)`, unicode61 remove_diacritics 2, prefix='2 3 4', bm25 weighted subject/from over body. Composite TEXT PK → FTS integer rowid via message_seq/fts_map. Maintain in the same write transaction. integrity-check in tests. 2–3 char query floor.
- Search = debounced cancellable `writer.read` (not ValueObservation); local-first FTS + async server `messages.list?q=` merge flagged server-sourced. Overlay JOIN composes so a just-archived hit drops from `in:inbox`.
- **Split inbox:** `split_rules` table + `split_key` written onto thread_rollup at maintenance time; **category splits fall out of persisted CATEGORY_* labels for free**; each split view is the same bounded index scan.
- `has_attachment` sourced at saveBody (hydration) time, eventually-consistent (metadata backfill has no attachment field); build attachments metadata table + flag at hydrate.
- **Land AIKit pre-M7 hooks here:** `ai_artifacts` + `ai_config` migrations, `threadMessages`/`sentMessages` Store reads, `LLMKeyStore` protocol + InMemory impl.
- **Biggest risk:** rollup maintenance amplifies the write path and the migration bulk-build runs over 100k messages — must be truly O(1)-incremental touching only the affected thread, or newest-first backfill of a 500-message thread degrades to ~250k row visits. Needs a high-message-count test.

### M5 — Send
**Goal:** correct RFC 5322 sends, bulletproof dedup, reply threading, plus an undo-send the spec doesn't call out.
- MIME: text/plain + text/html alternative, quoted history, attachments multipart/mixed; **threading triple** (threadId + References/In-Reply-To + matching normalized `Re:` Subject); edited subject starts a new thread; encoded-size validation at compose/enqueue. Golden-file tests assert all three.
- Send dedup: UUID Message-ID at enqueue (persisted); `pending→in_flight→sent` state machine, in_flight committed BEFORE the network call; unknown-outcome restart probes `q=rfc822msgid:<id> in:sent`. A fast miss is NOT proof of non-delivery — wait and re-probe rather than resend.
- **Undo-send:** user-cancellable hold (default ~10–30s) before pending→in_flight; cancel = local delete. Cheap parity win on the existing state machine.
- Sends use the M3 `post<Body,Response>` core.
- **Biggest risk:** kill-between-send-and-record + dedup-probe ambiguity — needs the §10 fault-injection suite to prove convergence.

### M6 — Scheduling (snooze + send-later)
**Goal:** survives device loss and a sleeping laptop.
- **Send-later = real Gmail draft:** `drafts.create` labeled Hudson/SendLater at schedule time, `drafts.send` at due time, delete mirror on cancel. Recoverable from any Gmail client — arguably better than Superhuman on reliability.
- **Snooze:** remove INBOX + add Hudson/Snoozed + `scheduled_jobs(kind:unsnooze, due_at)`.
- Scheduler arms a single timer (no tick loop); wraps the imminent-send window in `ProcessInfo.beginActivity(.userInitiated)` so App Nap can't defer a send. Catch-up at launch AND `NSWorkspace.didWakeNotification` AND significant clock change.
- At-least-once with the M5 Message-ID dedup.
- **Biggest risk:** fully-asleep/off Mac fires jobs at next wake — inherent to serverless; document it, draft mirror is the recovery story.

### M7 — AIKit
(Full design above.) Ship summarize / draft-in-voice / ask-inbox as a quiet, explicit-invocation-only layer with the EgressGuard type-level guarantee.
- **Biggest risk:** pure-FTS5 retrieval misses paraphrase on ask-inbox and the two-hop latency (~3.5s) undercuts "AI-native" vs a semantic competitor; prompt-injection via retrieved bodies has no full v1 mitigation (bound context, cite sources, never execute).

### UI — SwiftUI shell
**Goal:** a thin shell over the same public APIs that actually hits the latency bar.
- Reactive reads observe the **overlay-merged effective state** (thread_rollup JOIN mutation_queue overlay), not raw canonical tables.
- Inbox observation queries thread_rollup ONLY; `.removeDuplicates()` everywhere; Combine `.throttle` (250–500ms) during backfill; keyset-windowed (LIMIT + `(last_message_at, thread_id)`) so a 200k list is never diffed whole.
- Instant first frame via async ValueObservation + skeleton row; instant triage from the M3 in-memory overlay.
- Account for per-connection memory: cache_size/mmap_size are per-connection (~6x across the reader pool); size `maximumReaderCount`; cap per-connection mmap vs WKWebView.
- Warm-cache adjacency prefetch keyed to the j/k cursor; unhydrated neighbors get a REAL on-demand priority-lane fetch.
- Thread open paints headers + plain-text first; WKWebView progressive. Chunk/virtualize long threads.
- **Command palette (⌘K)** = a UI command registry dispatching through public APIs, sharing one action catalog with the CLI verb list.
- **AI is quiet:** keystroke-triggered, inline, dismissible, attributable, reversible; degrades silently to the fast mailbox on no-key/offline/refusal; never in the triage critical path.
- **Biggest risk:** cold-start contention — during the ~6h backfill every batched hydration commit and 15s poll re-diffs every active observation on the bounded reader pool, competing for the keystroke-to-repaint budget precisely when first impressions form. Holds only if windowing + throttle + page-batching + in-memory overlay all land together.

## Open product decisions (for the user)

1. **Default AI provider** — designs assume Claude as default (quality, refusal semantics, cache behavior all designed around it), others user-selectable. Confirm Claude-as-default vs provider-agnostic first-run choice. *(Controller lean: Claude default, since it's user-configurable anyway.)*
2. **Embeddings** — v1 is pure FTS5/BM25, which caps ask-inbox recall on paraphrase ("contract renewal" won't match "agreement extension"). Accept the lexical ceiling for v1 with sqlite-vec RRF as funded v2, or is semantic retrieval a v1 must-have?
3. **Ambient AI vs the privacy invariant** — Superhuman's always-visible auto-summary / Slashy's always-on learned triage are architecturally incompatible with "no background AI egress, ever" (they'd egress every thread scrolled past). Accept the honest gap (explicit-invocation summarize + bounded user-triggered pre-warm), or relax the invariant to allow opt-in background summarization?
4. **v1 scope cuts** — snippets, auto follow-up reminders, and AI-learned priority triage are the clearest Superhuman/Slashy features Hudson v1 lacks. Confirm acceptable to acknowledge rather than ship.
5. **Substring search** — prefix index makes "meet" match "meeting" instantly but won't match "bar" inside "foobar". Accept prefix-only for v1, or pay ~3x FTS index size (interacts with backfill disk footprint) for a trigram tokenizer?
