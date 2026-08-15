# AIKit

`Sources/AIKit/` — LLM providers, the egress choke point, and the four AI
features. Depends on `Store` (retrieval, artifact cache, config) and on
`GmailKit` **only** for the `LLMKeyStore` Keychain seam.

> **AIKit must never touch `GmailClient` or any Gmail network path.** The
> constraint is written into `Package.swift`'s dependency comment. AIKit's
> network egress is to LLM providers and nothing else.

Every design choice in this module serves one guarantee: **mail content leaves
the machine only when a person explicitly asks, to a provider they configured,
under a key they own.** See
[ai-privacy-model.md](../explanation/ai-privacy-model.md) for the reasoning;
this page is the API.

## The egress path

```
Invocation.userInvoked(.summarize)      private init — the compile-time gate
        │
        ▼
EgressGuard.run(request, for:)          ai_config.opt_in — the runtime gate
        │
        ▼
LLMProvider.stream(request)             the only call site in the codebase
```

### Invocation

```swift
public struct Invocation: Sendable {
    public let feature: AIFeature
    public static func userInvoked(_ feature: AIFeature) -> Invocation
    // init is private
}
```

A token proving one explicit user action asked for one AI feature to run. The
initializer is `private`, so no background task, timer, scroll handler, or
sync callback can fabricate one. Mint it at — and only at — a user-action
boundary: a CLI subcommand's `run()`, a UI button handler.

Grep `userInvoked` to enumerate every user action in the codebase that can
reach the network.

### EgressGuard

```swift
public actor EgressGuard {
    public init(provider: any LLMProvider, database: HudsonDatabase, account: String)
    public func run(_ request: LLMRequest, for invocation: Invocation)
        async throws -> AsyncThrowingStream<LLMEvent, Error>
}
```

The single internal choke point through which mail content may leave the
machine, and the only code that calls `provider.stream`. No feature module
holds a `provider` reference.

It checks `ai_config.opt_in` for `invocation.feature` and throws
`AIError.notOptedIn` **before any network call**. A missing row (never
configured) fails the same way — the gate is fail-closed.

An `actor` because it is network-driven shared state; the provider and
database handles are serialized through it.

## Provider protocol

```swift
public protocol LLMProvider: Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}
```

One streaming verb. There is intentionally **no buffered variant** — SSE
first-token latency is a product requirement, and buffering a whole `Data`
blob cannot stream it.

```swift
public struct LLMRequest: Sendable {
    public let model: String
    public let system: String?
    public let messages: [LLMMessage]
    public let maxTokens: Int
}
```

Deliberately carries only fields portable across Anthropic and
OpenAI-compatible APIs. The 5-series sampling knobs
(`temperature`/`top_p`/`top_k`/`budget_tokens`) are **absent by
construction** — they 400 on Opus/Sonnet/Fable 5, so there is no field through
which a caller could set them.

```swift
public enum LLMEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case usage(inputTokens: Int, outputTokens: Int)
    case refusal
    case stopped
}
```

`.thinkingDelta` is surfaced rather than dropped, so the UI can show thinking
progress without conflating it with the answer. `.refusal` is its own case so
callers branch on it *before* reading any `.textDelta` — a 5-series
`stop_reason == "refusal"` arrives with no usable content.

`LLMMessage.text` is **always plain text**. Feature modules build context from
message bodies' plain text, never raw HTML: markup would leak tracking
structure and waste the token budget.

### Implementations

| Provider | Notes |
|---|---|
| `AnthropicProvider` | The Anthropic Messages API |
| `OpenAICompatProvider` | Any OpenAI-compatible endpoint — set `--base-url` for Ollama (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`), OpenRouter, … |

Both take an `LLMHTTP` for transport:

```swift
public protocol LLMHTTP: Sendable {
    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error>
}
```

`URLSessionLLMHTTP` in production; `ScriptedLLMHTTP` / `FlakyLLMHTTP` /
`StubURLProtocol` in tests.

`SSEFraming.frame(_:) -> (events: [SSEEvent], remainder: Data)` is the pure
server-sent-events framer both providers share — chunk boundaries land
anywhere, so the remainder carries across reads.

## Features

Four features, each independently opt-in via its own `ai_config` row. Turning
on summarize never turns on ask-inbox.

```swift
public enum AIFeature: String, Sendable {
    case summarize, draft, ask, voiceProfile
}
```

The raw values are the `feature` column key — a storage contract, not labels.

### Summarize

```swift
public struct Summarize: Sendable {
    public init(`guard`: EgressGuard, database: HudsonDatabase, account: String)
    public func summarize(threadID: String, invocation: Invocation)
        async throws -> AsyncThrowingStream<String, Error>
}
```

Default model `claude-haiku-4-5`; 1024 max tokens; a 2–4 sentence neutral
summary.

**Content-addressed cache** on `(thread_id, last_message_id)`. Re-summarizing
an unchanged thread is a local `ai_artifacts` read with **zero egress** — and
a cache hit returns without ever calling `EgressGuard`, so a re-view exercises
no code path that could egress. New mail in the thread changes
`last_message_id`, which changes the key, forcing a correct regeneration
rather than silently serving a stale summary.

Cached artifacts record every message in the thread as a `source`, so deleting
any one of them purges the summary (`AIArtifacts.purge`).

Throws `AIError.emptyThread` for an unknown thread id, before any cache lookup
or egress.

### Draft

```swift
public struct Draft: Sendable {
    public func draft(…, invocation: Invocation) async throws -> AsyncThrowingStream<String, Error>
}
```

Drafts a reply in the user's own voice, using the `VoiceProfile` below.

### VoiceProfile

```swift
public struct VoiceProfile: Sendable {
    public func current(invocation: Invocation, forceRefresh: Bool) async throws -> String
}
```

Derives a description of how the user writes, from their own sent mail, and
caches it. A **separate** `AIFeature` case and therefore a separate opt-in
row: analyzing your sent mail is a distinct consent from drafting one reply.

### AskInbox

```swift
public struct AskInbox: Sendable {
    public static let defaultModel = "claude-sonnet-5"
    public func ask(_ question: String, invocation: Invocation)
        async throws -> AsyncThrowingStream<AskEvent, Error>
}

public enum AskEvent: Sendable, Equatable {
    case textDelta(String)
    case citations([String])
    case coverage(hydratedFraction: Double)
}
```

Retrieve-then-answer over the whole inbox. Retrieval is local FTS5 with zero
egress. Up to **two** egresses per call, both gated by the same `.ask` opt-in:

1. An **optional** Haiku query-expansion hop for non-lexical questions —
   skipped entirely for a keyword query. It is a retrieval-quality
   optimization, not a separately consentable feature, which is why it has no
   `AIFeature` case of its own.
2. The Sonnet cited-answer hop, always performed.

Egress is the question plus the top-k retrieved messages. Nothing else.

`.citations` reports the **deterministic retrieval set** — every message that
reached the prompt — not a parse of which ids the free-form answer text
mentioned. Parsing citation brackets back out of model output is one more
thing that could silently drop a citation; the retrieval set is exact by
construction.

`.coverage` reports the fraction of retrieved messages whose body was actually
hydrated, surfacing the "search coverage during hydration" caveat: an answer
built while backfill is still running is working from less than the full
mailbox, and the user is told so. It is `1.0` when nothing was retrieved —
vacuously covered, not "0% covered".

Both terminal events are emitted **even on a refusal**: retrieval already
happened, and the coverage promise does not lapse because the model declined.

**Prompt-injection posture.** The answer system prompt instructs the model to
treat retrieved message content as data to read, never as commands to obey.
Mail is hostile input on the way in *and* on the way to the model.

## Errors

```swift
public enum AIError: Error, Equatable, Sendable {
    case notOptedIn(AIFeature)   // thrown before any network I/O
    case transport(String)
    case httpStatus(Int)         // raw status, so callers can branch on 429
    case emptyThread(String)
}
```

## Configuration

Config lives in `ai_config`, written by `hudson ai config` or the app's
Settings sheet. API keys live in the Keychain under `com.hudson.llm` via
`LLMKeyStore` — never in the database, never in the repo.

```bash
hudson ai config --feature summarize --provider anthropic \
  --model claude-haiku-4-5 --api-key sk-ant-… --opt-in

# a local model, no key needed
hudson ai config --feature ask --provider openai-compat \
  --model llama3.1 --base-url http://localhost:11434/v1 --opt-in
```

**Omitting `--opt-in` resets opt-in to off.** Passing the flag is the only way
to turn it on — there is no way to leave it enabled by accident while changing
some other setting.

## Wiring it up

```swift
let provider = AnthropicProvider(apiKey: key, http: URLSessionLLMHTTP())
let guard_ = EgressGuard(provider: provider, database: db, account: email)
let summarize = Summarize(guard: guard_, database: db, account: email)

let stream = try await summarize.summarize(
    threadID: id, invocation: .userInvoked(.summarize))
for try await chunk in stream { print(chunk, terminator: "") }
```

The app does this in `AIBootstrap`; the CLI in `AICommands.swift`.

## Tests

`Tests/AIKitTests/` — 14 files. `EgressGuardTests` covers the opt-in gate;
`SSEFramingTests` covers chunk-boundary framing; `AnthropicProviderTests` and
`OpenAICompatProviderTests` cover wire formats; `SummarizeTests`,
`DraftTests`, `AskInboxTests`, `VoiceProfileTests` cover the features. Doubles
live in `ScriptedProvider.swift`, `ScriptedLLMHTTP.swift`,
`FlakyLLMHTTP.swift`, `StubURLProtocol.swift`.

## Related

- [ai-privacy-model.md](../explanation/ai-privacy-model.md) — the guarantee and how it is enforced
- [Store](store.md) — `ai_config`, `ai_artifacts`, retrieval
- [HudsonCLI](hudson-cli.md) — `hudson summarize` / `draft` / `ask` / `ai config`
