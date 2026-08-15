# HudsonCLI

`Sources/HudsonCLI/` — the `hudson` executable. Built on
[swift-argument-parser](https://github.com/apple/swift-argument-parser); 17
files, one per command group.

The CLI is not a lesser sibling of the app. It is the headless surface over the
same foundation, and it was the way every milestone was verified before any UI
existed. Anything the app can do, the CLI can do.

```bash
swift build
./Scripts/sign-cli.sh          # once per rebuild, so the Keychain trusts it
.build/debug/hudson --help
```

## Runtime wiring

Two object graphs, in `Runtime.swift`:

| | Opens | Keychain | Network | Used by |
|---|---|---|---|---|
| `LocalRuntime` | database + primary account | no | no | `list`, `show`, `search`, `inbox`, `pending`, `sync --status` |
| `Runtime` | + `GmailClient`, `SyncEngine`, `MutationFlusher` | yes | yes | `sync`, `profile`, triage flush, `send`, `reply` |

Both run `AccountsMigration.runIfNeeded` (the one-time import of the legacy M1
`accounts.json`) and throw `GmailError.auth` if no account is connected.

The split matters: read commands never touch the Keychain, so they never
prompt and never need signing to behave.

## Commands

### Setup

```bash
hudson auth        # ~5-minute guided Google Cloud OAuth setup
hudson profile     # the connected account's live Gmail profile
```

`auth` walks the user through creating their own free OAuth client, runs the
PKCE + loopback flow, and stores tokens in the Keychain. See
[GmailKit](gmailkit.md) for the flow.

### Sync

```bash
hudson sync            # sync to completion
hudson sync --once     # exactly one bounded pass
hudson sync --status   # local sync state, no network
```

`--status` is the diagnostic: backfill state, history cursor, hydration
progress, pending mutation count.

### Reading

```bash
hudson list [--limit 25]              # newest messages from the local store
hudson show <id>                      # one message, sanitized
hudson search <query> [--limit 25] [--inbox]
hudson inbox [--split <name>] [--limit 25]
```

All four are pure local reads — no network, no Keychain. `search` is FTS5 over
the local index; `--inbox` scopes it to messages whose *effective* labels
include INBOX, so an optimistically-archived message drops out immediately.

`inbox` is thread-grouped and split-aware; Gmail's own categories map to
splits automatically.

### Triage

```bash
hudson archive <id> [--no-flush]
hudson unarchive <id>
hudson star <id> / hudson unstar <id>
hudson read <id> / hudson unread <id>
hudson label <id> [--add <label> …] [--remove <label> …]
hudson pending                        # queued, not yet confirmed by Gmail
hudson undo <id>                      # undo the most recent action on a message
```

Every triage command does the same two things: enqueue the delta locally via
`LocalRuntime` (instant, optimistic — the effect is visible in `list`/`inbox`
before any network call), then flush best-effort via `Runtime`.

`--no-flush` skips the network half. Useful offline, and useful for
demonstrating that the local effect is genuinely independent of the network.

`pending` shows the raw queue: message id, op, label id, and state
(`pending`/`in_flight`).

See [optimistic-mutations.md](../explanation/optimistic-mutations.md).

### Sending

```bash
hudson send --to a@example.com --subject "Hi" [--body "…"] [--attach path …]
hudson reply <thread-id> [--all] [--body "…"]
```

Both accept `--to`/`--attach` repeatedly. Omit `--body` to read the body from
stdin:

```bash
echo "Sounds good" | hudson reply 18f2c… --all
```

`reply` builds the full threading triple from the thread's newest local
message. Both enqueue a durable job with a 15-second undo hold and then flush.
See [Outbox](outbox.md).

### AI

```bash
hudson summarize <thread-id>
hudson draft [--reply <thread-id>] --instruction "decline politely"
hudson ask "what did legal say about the lease?"

hudson ai config --feature <summarize|draft|ask|voiceProfile> \
                 --provider <anthropic|openai-compat> \
                 --model <name> [--base-url <url>] [--api-key <key>] [--opt-in]
```

Each command mints exactly one `Invocation.userInvoked(...)` — that is the
compile-time proof a person asked. Output streams as it generates.

`ask` prints citations and a hydration-coverage line alongside the answer, so
you know how much of the mailbox the answer was actually built from.

**`--opt-in` is required to enable egress, and omitting it resets opt-in to
off.** There is no way to leave a feature enabled by accident while changing
some other setting.

```bash
# Anthropic
hudson ai config --feature summarize --provider anthropic \
  --model claude-haiku-4-5 --api-key sk-ant-… --opt-in

# a local model — no key at all
hudson ai config --feature ask --provider openai-compat \
  --model llama3.1 --base-url http://localhost:11434/v1 --opt-in
```

See [AIKit](aikit.md).

## Conventions

**Everything printed goes through `Sanitizer.terminalSafe`.** Sender names,
subjects, and label names are attacker-influenced text; a raw ANSI escape in a
Subject must not be able to repaint your terminal. Commands use
`singleLine: true` for row output.

**Errors are mapped, not dumped.** `GmailErrorReporting.reportAndFail(_:)`
turns a `GmailError` into an actionable message (`run 'hudson auth' first`)
and a non-zero exit, rather than surfacing a raw HTTP status.

**Commands are `AsyncParsableCommand`.** Each is a small struct with a
`CommandConfiguration` and a `run()`.

## Files

| File | Contents |
|---|---|
| `HudsonCommand.swift` | `@main`, the subcommand list |
| `Runtime.swift` | `LocalRuntime` / `Runtime` |
| `AuthCommand.swift` | the guided OAuth flow |
| `SyncCommand.swift`, `ProfileCommand.swift` | network commands |
| `ListCommand.swift`, `ShowCommand.swift`, `SearchCommand.swift`, `InboxCommand.swift` | local reads |
| `TriageCommands.swift` | archive/star/read/label/undo — all eight |
| `PendingCommand.swift` | queue inspection |
| `SendCommand.swift` | `send` + `reply` |
| `AICommands.swift` | `summarize`, `draft`, `ask`, `ai config` |
| `AccountsFile.swift`, `AccountsMigration.swift` | legacy `accounts.json` import |
| `ConsoleInput.swift` | prompting helpers for `auth` |
| `GmailErrorReporting.swift` | error → message + exit code |

## Adding a command

See [add-a-cli-command.md](../howto/add-a-cli-command.md).

## Tests

`Tests/HudsonCLITests/` — `RuntimeLocalTests`, `SendCommandTests`,
`AICommandsTests`, `UndoInverseDeltaTests`,
`TestingStatusDiagnosticTests`.

## Related

- [Store](store.md) — what every read command queries
- [SyncEngine](syncengine.md) — what `sync` drives
- [HudsonUI](hudson-ui.md) — the app over the same mailbox
