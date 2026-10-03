# Hudson

Fork local de Horacio: [horacioeps/hudson](https://github.com/horacioeps/hudson) (upstream: [mannasdev/hudson](https://github.com/mannasdev/hudson)). Diario de trabajo: [HISTORICO.md](HISTORICO.md).

A fast, open-source, Mac-native Gmail client. Superhuman-class speed, AI on
your own API keys, no subscription, no server, no telemetry.

## Download

<a href="https://tryhudson.email">
  <img alt="Download Hudson for Mac"
       src="https://img.shields.io/badge/Download-Hudson%20for%20Mac-2e5d50?style=for-the-badge&logo=apple&logoColor=white" />
</a>

Signed and Apple-notarized DMG — no Gatekeeper warning. **Apple silicon,
macOS 15+** (there is no Intel build).

On first launch Google shows a *"this app isn't verified"* screen. That is
expected: removing it requires an annual paid third-party security audit that a
free client isn't going to buy. Click **Advanced → Continue to Hudson**. Your
mail and tokens never leave your Mac — this repository is the proof, and
[`SharedOAuth.swift`](Sources/HudsonUI/Model/SharedOAuth.swift) is where the
sign-in credentials are resolved. If you'd rather not trust the bundled OAuth
client at all, **Use my own Google credentials** on the sign-in screen runs the
whole flow under a Google Cloud project you control.

> **Status:** beta. Sync, reading, keyboard triage, search, send, and
> explicitly-invoked AI all work. Snooze/send-later is not built yet, and there
> is no auto-update — new versions are re-downloaded from the site.

## Why

Superhuman costs $25–40/month. Slashy costs $25/month. Both are closed. Hudson
is the same class of product — keyboard-first triage, sub-100ms feel, AI
drafting/summarizing/search — built openly, for free, with your own Google
OAuth client and your own LLM API keys. Nothing between you and your mail.

## Try the foundation (CLI)

Requires macOS 15+ and Xcode 16+.

```bash
git clone https://github.com/hudson-mail/hudson && cd hudson
swift build
./Scripts/sign-cli.sh          # stable signing so the Keychain trusts rebuilds
.build/debug/hudson auth       # ~5-minute guided Google OAuth setup
.build/debug/hudson profile    # your live Gmail profile
.build/debug/hudson sync       # download your mailbox into the local store
.build/debug/hudson list       # newest messages, straight from SQLite
.build/debug/hudson show <id>  # one message, sanitized, instant
.build/debug/hudson archive <id>     # archive (instant, optimistic)
.build/debug/hudson star <id>        # star
.build/debug/hudson read <id>        # mark read
.build/debug/hudson pending          # queued triage actions
.build/debug/hudson undo <id>        # undo a triage action
.build/debug/hudson search <query>   # instant local full-text search
.build/debug/hudson inbox --split <name>  # thread-grouped inbox with split tabs (Gmail categories work automatically)
```

`hudson auth` walks you through creating your **own** free Google Cloud OAuth
client — that's the trick that keeps Hudson free and unverified-fee-free
forever. Your tokens live in your Keychain. Nothing phones home.

## Run the app

The Mac-native SwiftUI shell — a three-pane mailbox with keyboard-first
triage (`j`/`k`/`e`/`s`/`u`), a ⌘K command palette, and local search — reads
and triages the SAME local mailbox the CLI above syncs:

```bash
swift run HudsonApp          # reads ~/Library/Application Support/Hudson/hudson.sqlite
swift run HudsonApp --demo   # a synthetic ~40-thread demo mailbox — no real account needed
```

Full keyboard map and what's still stubbed pending later milestones (send,
AI, snooze): [`docs/ui/running-the-app.md`](docs/ui/running-the-app.md).

## Roadmap

Foundation (headless, CLI-verified): auth → sync engine → triage mutations →
search & split inbox → send → snooze/send-later → AI (Anthropic +
OpenAI-compatible/local). Then: the SwiftUI app, designed by a real designer.
Details: [the spec](docs/superpowers/specs/2026-08-10-hudson-foundation-design.md).

## Documentation

Start at [`docs/README.md`](docs/README.md) — the full index.

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together
- [CLAUDE.md](CLAUDE.md) — working in this codebase (for humans and AI agents)
- [Module reference](docs/reference/) — one page per target: GmailKit, Store,
  SyncEngine, Outbox, AIKit, HudsonCLI, HudsonUI
- Why it works the way it does:
  [local-first sync](docs/explanation/local-first-sync.md) ·
  [optimistic triage](docs/explanation/optimistic-mutations.md) ·
  [the AI privacy model](docs/explanation/ai-privacy-model.md)
- How to [add a CLI command](docs/howto/add-a-cli-command.md) or
  [cut a release](docs/howto/build-and-release.md)

## Contributing

The spec is the source of truth; every milestone lands with tests
(`swift test`). Readability is a feature — if something is hard to follow,
that's a bug worth filing.

Read [CLAUDE.md](CLAUDE.md) first — it covers the build/test loop, the module
dependency rules, and the seven invariants that are enforced by structure
rather than convention.

## License

MIT (see LICENSE).
