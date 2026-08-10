# Hudson

A fast, open-source, Mac-native Gmail client. Superhuman-class speed, AI on
your own API keys, no subscription, no server, no telemetry.

> **Status:** pre-alpha. The headless core is being built milestone by
> milestone ([spec](docs/superpowers/specs/2026-08-10-hudson-foundation-design.md));
> the Mac app UI follows. Today you can authenticate, sync your mailbox into a local SQLite store, and read it back instantly from the CLI.

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
```

`hudson auth` walks you through creating your **own** free Google Cloud OAuth
client — that's the trick that keeps Hudson free and unverified-fee-free
forever. Your tokens live in your Keychain. Nothing phones home.

## Roadmap

Foundation (headless, CLI-verified): auth → sync engine → triage mutations →
search & split inbox → send → snooze/send-later → AI (Anthropic +
OpenAI-compatible/local). Then: the SwiftUI app, designed by a real designer.
Details: [the spec](docs/superpowers/specs/2026-08-10-hudson-foundation-design.md).

## Contributing

The spec is the source of truth; every milestone lands with tests
(`swift test`). Readability is a feature — if something is hard to follow,
that's a bug worth filing.

## License

MIT (see LICENSE).
