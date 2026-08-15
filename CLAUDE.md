# CLAUDE.md — working in the Hudson repo

Orientation for AI agents and new contributors. Read this before touching
code. For how the pieces fit together, read [ARCHITECTURE.md](ARCHITECTURE.md)
next; for a module's actual API, read its page under [`docs/reference/`](docs/reference/).

## What this is

Hudson is a Mac-native Gmail client: a Swift 6 package (`Package.swift`, no
Xcode project) that builds a headless CLI and a SwiftUI app over the same
local SQLite mailbox. No server, no backend, no telemetry. The user's mail,
OAuth tokens, and LLM API keys never leave their Mac.

## Build, run, test

```bash
swift build                       # whole package
swift test                        # whole suite — the gate for every change
swift test --filter StoreTests    # one target
swift test --filter MimeBuilderTests.buildsMultipart   # one test

swift run HudsonApp               # the SwiftUI app, real mailbox
swift run HudsonApp --demo        # ~40 synthetic threads, no account needed
.build/debug/hudson --help        # the CLI
```

Requires macOS 15+ and Xcode 16+. `swift build` is the fast feedback loop;
there is no lint step and no formatter config — match surrounding style.

After `swift build`, run `./Scripts/sign-cli.sh` once per rebuild if you are
exercising the CLI against a real account: without a stable code-signing
identity the Keychain re-prompts on every rebuild (spec §6.3).

## Module map

Eight targets under `Sources/`. Arrows are "depends on".

```
HudsonApp ──> HudsonUI ──┬──> GmailKit
                         ├──> Store ──> GRDB
                         ├──> SyncEngine ──> GmailKit, Store
                         ├──> Outbox ──> GmailKit, Store
                         └──> AIKit ──> Store, GmailKit*

HudsonCLI ──> GmailKit, Store, SyncEngine, Outbox, AIKit, ArgumentParser
```

| Target | Files | What it owns | Reference |
|---|---:|---|---|
| `GmailKit` | 21 | OAuth, Keychain, the typed Gmail API client, quota | [gmailkit.md](docs/reference/gmailkit.md) |
| `Store` | 23 | SQLite schema, migrations, all reads/writes, FTS, queues | [store.md](docs/reference/store.md) |
| `SyncEngine` | 4 | Backfill, history polling, body hydration, mutation flush | [syncengine.md](docs/reference/syncengine.md) |
| `Outbox` | 5 | MIME building, reply threading, the send state machine | [outbox.md](docs/reference/outbox.md) |
| `AIKit` | 11 | LLM providers, the egress choke point, summarize/draft/ask | [aikit.md](docs/reference/aikit.md) |
| `HudsonCLI` | 17 | The `hudson` executable and its subcommands | [hudson-cli.md](docs/reference/hudson-cli.md) |
| `HudsonUI` | 47 | SwiftUI views, view models, theme, keyboard routing | [hudson-ui.md](docs/reference/hudson-ui.md) |
| `HudsonApp` | 1 | `@main` shell that mounts `RootView` | — |

\* `AIKit` depends on `GmailKit` **only** for the `LLMKeyStore` Keychain seam.
It must never touch `GmailClient` or any Gmail network path (spec §8). The
dependency comment in `Package.swift` says so; keep it true.

## Invariants — do not break these

These are load-bearing. Each one is enforced by code structure, not by
convention, and each has tests. If a change appears to require breaking one,
that is a design discussion, not a refactor.

1. **Migrations are append-only.** Never edit a registered migration in
   `Sources/Store/Migrations.swift` after it ships — add `v11`. Installed
   databases have already run the old one.
2. **Triage never writes canonical tables.** An archive/star/read enqueues a
   row into `mutation_queue`; reads compose the overlay on top of canonical
   truth. See [optimistic-mutations.md](docs/explanation/optimistic-mutations.md).
3. **Nothing reaches the terminal or the search index except through
   `Sanitizer`.** `SanitizedBody` has no public initializer, by design —
   it is only ever the output of `Sanitizer.sanitize`.
4. **`EgressGuard.run` is the only code that calls `provider.stream`,** and
   it requires an `Invocation`, whose initializer is private. That makes "no
   background AI egress" a compile-time property. See
   [ai-privacy-model.md](docs/explanation/ai-privacy-model.md).
5. **Never clobber newer server state.** Writes are version-guarded on
   `history_id` (spec §4.2); re-applying a stale snapshot must be a no-op.
6. **No secrets in the repo.** CI runs a secret scan (`.github/workflows/ci.yml`)
   that fails on OAuth client secrets, private keys, and `ya29.` tokens. The
   shared *client ID* is public and intentionally committed; the *secret*
   lives in git-ignored `Scripts/hudson-secrets.env`.
7. **Store access is `async` through `HudsonDatabase`.** Never reach for the
   GRDB `writer` from another module or block a cooperative-pool thread.

## Conventions

**Comments explain why, not what.** This codebase's doc comments are unusually
dense and that is deliberate — they record the reasoning behind a non-obvious
choice, and often reference the spec section that motivated it. When you make
a subtle decision, write it down the same way. When you change behavior a
comment describes, update the comment in the same edit.

**Spec references.** `§4.2`, `§7.3`, and similar point at
[the foundation spec](docs/superpowers/specs/2026-08-10-hudson-foundation-design.md).
Milestone tags (`M1`–`M7`, `U1`, `D1`) point at
[`docs/superpowers/plans/`](docs/superpowers/plans/). The spec is the source
of truth for intent.

**Concurrency.** Swift 6 strict mode. Network-driven shared state is an
`actor` (`SyncEngine`, `MutationFlusher`, `SendService`, `QuotaBucket`,
`EgressGuard`, `AccountSession`). Everything SwiftUI touches is
`@MainActor @Observable`. Actors are re-entrant, so any actor with a
multi-step network pass carries an explicit single-flight guard — copy that
pattern rather than assuming isolation is enough.

**Test seams are protocols, not mocks of URLSession.** `GmailAPI`,
`SendTransport`, `LLMProvider`, `LLMHTTP`, `HTTPTransport`, and `TokenStore`
all exist so tests script a server instead of stubbing HTTP. Use the existing
doubles in `Tests/*/Support/`.

**Tests are not optional.** Every milestone lands with tests; `swift test`
green is the bar for a commit. Store changes need a migration test.

## Where things live

```
Sources/            the eight targets above
Tests/              one test target per source target, same names
docs/               human + agent documentation (start at docs/README.md)
docs/superpowers/   the spec, milestone plans, and design docs
Scripts/            sign-cli.sh, package-app.sh, make-dmg.sh
Design/             app icon master, DMG background (regenerated art)
web/                the tryhudson.email landing page
dist/               build output, git-ignored
```

Runtime data lives outside the repo, in
`~/Library/Application Support/Hudson/hudson.sqlite`. The CLI and the app
share it. Tokens live in the login Keychain under `com.hudson.gmail`; LLM keys
under `com.hudson.llm`.

## Common tasks

- Add a CLI subcommand → [docs/howto/add-a-cli-command.md](docs/howto/add-a-cli-command.md)
- Cut a signed, notarized release → [docs/howto/build-and-release.md](docs/howto/build-and-release.md)
- Change the schema → add a migration in `Sources/Store/Migrations.swift`,
  add a test in `Tests/StoreTests/MigrationTests.swift`
- Run the app and eyeball a UI change → `swift run HudsonApp --demo`, then
  see [docs/ui/running-the-app.md](docs/ui/running-the-app.md)

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
