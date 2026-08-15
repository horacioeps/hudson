# How "no background AI egress" is enforced

Hudson's AI promise is narrow and absolute: **mail content leaves the machine
only when a person explicitly asks, to a provider they configured, under a key
they own.** No ambient summarization, no background classification, no
telemetry, no Hudson-operated server anywhere in the path.

This page is about why that promise is enforced by the type system and the
schema rather than by discipline.

Spec §8. Implemented in `AIKit/Invocation.swift`, `AIKit/EgressGuard.swift`,
`AIKit/LLMProvider.swift`, and `Store`'s `ai_config` / `ai_artifacts` tables.

## The problem

"We don't send your email anywhere without asking" is the easiest promise in
software to make and the easiest to break. It breaks quietly, in a code
review nobody caught:

- A `.onAppear` that pre-summarizes the visible thread, "for responsiveness".
- A scroll handler that warms a cache.
- A background task that builds an embedding index.
- A helpful refactor that hoists a provider call into a shared utility, and a
  second call site that inherits it.

None of these are malicious. Each is a reasonable-looking optimization. And in
a codebase where any module can hold a provider reference and call
`stream()`, each is one merged PR away.

A policy — "don't do that" — does not survive a year of changes and a growing
contributor count. And the user cannot verify a policy. They can only verify
structure.

So the requirement is stronger than "don't egress in the background". It is:
**make background egress not expressible.**

## The design: two gates, different kinds

```
explicit user action
        │
        ▼
Invocation.userInvoked(.summarize)     ← gate 1: COMPILE TIME
        │                                 private init
        ▼
EgressGuard.run(request, for:)         ← gate 2: RUN TIME
        │                                 ai_config.opt_in, fail-closed
        ▼
LLMProvider.stream(request)            ← the only call site in the codebase
```

Two gates that fail for different reasons, so no single mistake opens both.

### Gate 1: the Invocation token (compile time)

```swift
public struct Invocation: Sendable {
    public let feature: AIFeature
    private init(feature: AIFeature) { … }
    public static func userInvoked(_ feature: AIFeature) -> Invocation
}
```

`EgressGuard.run` requires an `Invocation`. The initializer is **private**, so
the only way to obtain one is `userInvoked(_:)`.

That is the whole trick. A background task, a timer, a scroll handler, a sync
callback — none of them can fabricate one. Not "shouldn't": *can't*. The
absence of an ambient constructor is a compile-time guarantee, not a
convention a reviewer has to police.

The naming is chosen for auditability. Every call site reads as
`Invocation.userInvoked(.summarize)`, so a reviewer — or a user reading the
source, which is the point of shipping it open — can grep one identifier and
enumerate every user action in the codebase that can reach the network.

Holding an `Invocation` is equivalent to the user having pressed the button.
That is why it is minted at the user-action boundary and nowhere else: a CLI
subcommand's `run()`, a UI button handler. In the whole app, `SummaryModel`'s
tap handler is the only UI site that mints one.

### Gate 2: the EgressGuard (run time)

```swift
public actor EgressGuard {
    public func run(_ request: LLMRequest, for invocation: Invocation)
        async throws -> AsyncThrowingStream<LLMEvent, Error>
}
```

The single internal choke point through which mail content may leave, and the
**only code in the codebase that calls `provider.stream`**. No feature module
holds a provider reference. `Summarize`, `Draft`, `AskInbox`, and
`VoiceProfile` all obtain their stream through `run(_:for:)`.

It checks `ai_config.opt_in` for the invoked feature and throws
`AIError.notOptedIn` **before any network call**. A missing row — a feature
never configured — fails the same way. **Fail-closed**: the default state of a
feature nobody set up is "off", not "on".

Per-feature, not global. Turning on summarize does not turn on ask-inbox.
Analyzing your sent mail to build a voice profile is its own `AIFeature` case
and its own consent, separate from drafting a single reply — because they are
different asks.

### Why two gates

They fail independently:

- Gate 1 fails at compile time and catches *structural* mistakes — a new
  background code path trying to egress. It cannot be forgotten, because the
  code will not build.
- Gate 2 fails at run time and catches *consent* mistakes — a real user action
  for a feature this user never enabled. It cannot be bypassed, because
  `run` is the only door.

A single bad refactor cannot open both. Deleting the opt-in check leaves the
token requirement; making `init` public leaves the opt-in check.

## Fail-closed all the way up

The guarantee holds at the UI layer too. `AIBootstrap` builds AIKit features
from `ai_config` + Keychain and returns `nil` when a feature is not opted in —
so **no provider object is ever constructed**. The Summarize chip degrades to
a "turn AI on" affordance. There is no built-but-unused provider sitting
around for a future code path to find.

Same shape in the CLI: `hudson ai config` writes the row, and omitting
`--opt-in` **resets opt-in to off**. Passing the flag is the only way to turn
it on, so there is no way to leave a feature enabled by accident while
changing some other setting.

## What actually leaves

Being precise about the payload matters as much as gating it.

| Feature | Egress |
|---|---|
| Summarize | One thread's messages, plain text |
| Draft | The instruction, the thread being replied to, the voice profile |
| Ask-inbox | The question + the top-k retrieved messages |
| VoiceProfile | A sample of the user's own sent mail |

Three properties of that payload:

**Plain text only, never raw HTML.** `LLMMessage.text` is always plain text.
Raw markup would leak tracking structure — pixel URLs, per-recipient tracking
parameters, the shape of who mailed you — and waste the token budget. Feature
modules build context from stored `plain_text`, which has already been through
`Sanitizer`.

**Retrieval is local.** Ask-inbox's retrieval is FTS5 over the local index:
zero egress. Only the *selected* messages are sent, not the mailbox. The
optional query-expansion hop sends the question — never mail — and is skipped
entirely for a lexical query.

**No key ever goes to Hudson.** API keys live in the Keychain under
`com.hudson.llm`, never in the database, never in the repo. Anthropic, or an
OpenAI-compatible endpoint the user names — including `localhost`, which is
the fully offline answer: point `--base-url` at Ollama or LM Studio and
nothing leaves the machine at all.

## Caching as an egress reduction

Summaries are cached in `ai_artifacts`, content-addressed on
`(thread_id, last_message_id)` plus model and prompt version.

A cache hit returns **without ever calling `EgressGuard`**. Not "calls it and
skips the network" — the guard is never reached, so a re-view exercises no
code path that could possibly egress. Re-reading a summary is a local SQLite
read.

New mail in the thread changes `last_message_id`, which changes the key, which
forces a fresh generation. Correctness and privacy point the same direction:
you cannot be silently served a stale summary, and you cannot be silently
re-charged for an unchanged one.

Artifacts record their source messages in `ai_artifact_sources`, so deleting a
message purges the AI content derived from it. Derived content inherits the
lifetime of its source — otherwise "delete this email" would leave a summary
of it sitting in the database.

> That table's schema was corrected in migration `v6`. It originally linked to
> `ai_artifacts`' *implicit rowid*, which SQLite may renumber on `VACUUM` — a
> renumbered rowid would make purge delete the wrong artifact, and cached AI
> content of a deleted message surviving is exactly the invariant failure this
> table exists to prevent. `v6` stores the composite key parts instead, so the
> lookup has no rowid dependency by construction.

## Prompt injection

Mail is hostile input on the way in — that is what `Sanitizer` is for — and it
is hostile on the way to the model too. A message body reaching an LLM prompt
is attacker-controlled text sitting next to your instructions.

Ask-inbox's system prompt says so explicitly: treat retrieved message content
as data to read, never as commands to obey.

Citations reinforce it structurally. `.citations` reports the **deterministic
retrieval set** — every message that reached the prompt — not a parse of which
ids the answer text happened to mention. Parsing citation brackets back out of
model output is one more thing that could silently drop or invent a citation;
the retrieval set is exact by construction and can never under- or
over-report.

## Honesty about quality

`.coverage(hydratedFraction:)` reports what fraction of retrieved messages had
a real body rather than a placeholder. An answer built while backfill is still
running is working from less than the full mailbox, and the user is told so
rather than being handed a confident answer over partial data.

It is surfaced **even on a refusal** — retrieval already happened by then, and
the promise does not lapse because the model declined to answer.

## Where the boundary is not

Worth stating plainly, because it is the most likely honest confusion:
**background mail sync is not an AI egress path.** The auto-sync loop fetches
the user's own mail directly, Mac ↔ Gmail, with no server in between. That is
being an email client.

What is banned is background *AI*: no summarize-on-open, no summarize-on-scroll,
no ambient classification. `SummaryModel.reset()` on every thread switch
exists to make that visible — a summary is per-thread, it never bleeds across
a switch, and clearing it never triggers a new one.

## See also

- [AIKit reference](../reference/aikit.md) — the API
- [Store reference](../reference/store.md#ai-tables) — `ai_config`, `ai_artifacts`
- [HudsonUI reference](../reference/hudson-ui.md) — `AIBootstrap`, `SummaryModel`
- [The spec §8](../superpowers/specs/2026-08-10-hudson-foundation-design.md) — the egress table
