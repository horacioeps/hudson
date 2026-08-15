# Hudson documentation

Everything written down about Hudson, organized by what you are trying to do.

## Start here

| If you want to… | Read |
|---|---|
| Use Hudson | [README.md](../README.md) |
| Work in this codebase (human or AI) | [CLAUDE.md](../CLAUDE.md) |
| Understand how it fits together | [ARCHITECTURE.md](../ARCHITECTURE.md) |
| Run the Mac app | [ui/running-the-app.md](ui/running-the-app.md) |

## Reference — what the code does

One page per module. Types, signatures, behavior, and the tests that cover it.

| Module | Owns |
|---|---|
| [GmailKit](reference/gmailkit.md) | OAuth, Keychain, the Gmail API client, quota |
| [Store](reference/store.md) | SQLite schema, migrations, reads/writes, FTS, queues |
| [SyncEngine](reference/syncengine.md) | Backfill, history polling, hydration, mutation flush |
| [Outbox](reference/outbox.md) | MIME building, reply threading, the send state machine |
| [AIKit](reference/aikit.md) | LLM providers, the egress choke point, the four AI features |
| [HudsonCLI](reference/hudson-cli.md) | The `hudson` executable and every subcommand |
| [HudsonUI](reference/hudson-ui.md) | SwiftUI views, view models, theme, keyboard routing |

## Explanation — why it works that way

The reasoning you cannot reconstruct from reading the code.

- [Why the mailbox is a local database](explanation/local-first-sync.md) —
  backfill windows, cursor discipline, the version guard, and what
  local-first costs
- [Why triage is a queue, not a write](explanation/optimistic-mutations.md) —
  instant archive that cannot corrupt server truth, and why the simpler
  designs fail
- [How "no background AI egress" is enforced](explanation/ai-privacy-model.md) —
  a private initializer and a fail-closed opt-in, instead of a policy

## How-to — accomplish a specific task

- [Add a CLI command](howto/add-a-cli-command.md)
- [Build and release](howto/build-and-release.md) — dev build → `.app` →
  signed, notarized DMG

## Design

- [UI design brief](design/ui-design-brief.md) — the design system
- [Running the app](ui/running-the-app.md) — keyboard map, demo mode,
  screenshots

## Source of truth

The spec is authoritative for intent. Code comments reference it by section
(`§4.2`, `§7.3`); milestone tags (`M1`–`M7`, `U1`, `U2`, `D1`) reference the
plans.

- [Foundation system design](superpowers/specs/2026-08-10-hudson-foundation-design.md) — the spec
- [Speed & AI architecture](superpowers/design/2026-08-10-speed-ai-architecture.md)
- [Seamless sharing & distribution](superpowers/design/2026-08-10-seamless-sharing-distribution.md)
- [Milestone plans](superpowers/plans/) — M1 auth · M2 store/backfill ·
  M3 mutations · M4 query layer · M5 send · M7 AIKit · U1 SwiftUI shell ·
  U2 compose · D1 onboarding

## Status

- [STATUS.md](../STATUS.md) — distribution state, credentials, known follow-ups

## Keeping these honest

A doc that lies is worse than no doc. When you change behavior a page
describes, update the page in the same commit. The reference pages name the
files they describe, so `git grep` for a filename will find its docs.
