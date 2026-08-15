# How to add a CLI command

Add a new `hudson <verb>` subcommand, wire it into the command tree, and test
it. This walks through a local read command; the variations for network and
triage commands are at the end.

## Prerequisites

- macOS 15+, Xcode 16+
- `swift build` succeeding in a clean checkout
- Familiarity with [`Sources/HudsonCLI/`](../reference/hudson-cli.md) — in
  particular the `LocalRuntime` / `Runtime` split

## Steps

### 1. Decide which runtime you need

This is the first decision and it determines almost everything else.

| Need | Use | Touches Keychain? | Touches network? |
|---|---|---|---|
| Read the local store | `LocalRuntime.local()` | no | no |
| Call Gmail | `Runtime.bootstrap()` | yes | yes |
| Optimistic triage | `TriageRunner.apply(…)` | on flush only | best-effort |

Prefer `LocalRuntime`. A read command that never touches the Keychain never
prompts and never needs code signing to behave, which makes it usable in
scripts and tests.

### 2. Create the command file

One file per command, or add to an existing group file (`TriageCommands.swift`
holds all eight triage verbs). Create
`Sources/HudsonCLI/StatsCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GmailKit
import Store

/// Prints a one-line count of locally stored messages — a local read
/// (`LocalRuntime`), never the network.
struct StatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show local mailbox counts."
    )

    @Option(help: "How many top labels to show.")
    var limit: Int = 5

    func run() async throws {
        do {
            let runtime = try await LocalRuntime.local()
            let messages = try await runtime.database.recentMessages(
                account: runtime.account.email, limit: limit)
            for message in messages {
                let subject = Sanitizer.terminalSafe(message.subject, singleLine: true)
                print(subject)
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
```

Three things in there are not optional:

- **`Sanitizer.terminalSafe`** on anything derived from mail. Subjects, sender
  names, and label names are attacker-influenced; a raw ANSI escape must not
  be able to repaint the user's terminal. Use `singleLine: true` for row
  output.
- **`catch let error as GmailError { throw reportAndFail(error) }`**.
  `GmailError` is not `LocalizedError`, so letting it reach ArgumentParser's
  default handler debug-prints it and escapes embedded newlines into one
  unreadable line — exactly where the highest-value diagnostics live.
  `reportAndFail` writes a clean message to stderr and returns `ExitCode.failure`.
- **A doc comment saying which runtime it uses.** Every other command has one.

### 3. Register it

Add the type to the subcommand list in `Sources/HudsonCLI/HudsonCommand.swift`:

```swift
subcommands: [AuthCommand.self, ProfileCommand.self,
              SyncCommand.self, ListCommand.self, ShowCommand.self,
              SearchCommand.self, InboxCommand.self,
              StatsCommand.self,          // ← add here
              ArchiveCommand.self, …]
```

Order in this array is the order in `hudson --help`. Group it with related
commands.

### 4. Build and run it

```bash
swift build
.build/debug/hudson stats --help
.build/debug/hudson stats --limit 3
```

Expected: your abstract and options in `--help`, and either output or
`No account connected — run 'hudson auth' first.` on stderr with exit code 1.

Verify the exit code, since that is what scripts see:

```bash
.build/debug/hudson stats; echo "exit: $?"
```

### 5. Test it

Add to `Tests/HudsonCLITests/`. Test the logic against an in-memory database
rather than shelling out to the binary:

```swift
import Foundation
import Store
import Testing
@testable import HudsonCLI

@Test func statsReadsFromTheLocalStore() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    // seed with Tests/StoreTests/Support/TestSeed.swift patterns

    let runtime = LocalRuntime(database: db, account: try #require(await db.primaryAccount()))
    let rows = try await runtime.database.recentMessages(account: "a@example.com", limit: 5)
    #expect(rows.count == 0)
}
```

**Never touch the real Keychain in a test** (spec §6.3). Inject
`InMemoryTokenStore` anywhere credentials are involved.

```bash
swift test --filter HudsonCLITests
```

### 6. Document it

Add the command to the table in
[`docs/reference/hudson-cli.md`](../reference/hudson-cli.md), and to the
command list in `README.md` if it is something a new user would reach for.

## Verification

```bash
swift build && swift test
.build/debug/hudson --help | grep stats
```

All three should succeed, and your command should appear in the help output
with its abstract.

## Variations

### A command that calls Gmail

```swift
func run() async throws {
    do {
        let runtime = try await Runtime.bootstrap()
        let profile = try await runtime.client.getProfile()
        print(profile.emailAddress)
    } catch let error as GmailError {
        throw reportAndFail(error)
    }
}
```

`Runtime.bootstrap()` throws `GmailError.auth` if no account is connected or
the Keychain has no client secret. Do not catch and continue — an actionable
error is the right outcome.

Run `./Scripts/sign-cli.sh` after each `swift build` when testing these
manually, or the Keychain re-prompts every rebuild.

### An optimistic triage command

Do not enqueue by hand. Use the shared runner, which enqueues locally, prints
the resulting effective label state, and best-effort flushes:

```swift
struct PinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin", abstract: "Pin a message.")

    @OptionGroup var triage: TriageArguments   // gives you `id` and `--no-flush`

    func run() async throws {
        try await TriageRunner.apply(
            id: triage.id,
            deltas: [LabelDelta(labelID: "STARRED", op: .add)],
            action: "pinned",
            noFlush: triage.noFlush)
    }
}
```

`TriageRunner` handles the whole contract: the local enqueue is the effect the
command promises, and a flush failure is reported but never fails the command
— delivery is separate from intent. See
[optimistic-mutations.md](../explanation/optimistic-mutations.md).

**Thread-level actions need every message.** If your action means "this
conversation" rather than "this message" — archiving, marking read — enqueue
the delta on every message in the thread that carries the label. A
thread-level rollup flag is an OR-aggregate, so touching only the newest
message is a silent no-op whenever an older one still carries it. See
`Triage.archiveThread`.

### A command with subcommands

`AICommands.swift` shows the pattern — `AICommand` declares its own
`subcommands: [AIConfigCommand.self]`, and only the parent is registered in
`HudsonCommand`.

## Troubleshooting

**`hudson: unknown subcommand`** — you built but did not add the type to
`HudsonCommand.configuration.subcommands`.

**`Error: auth("...\n...")` with escaped newlines** — you did not catch
`GmailError` and route it through `reportAndFail`.

**Keychain prompts on every run** — run `./Scripts/sign-cli.sh` after
`swift build`. Without a stable signing identity, each build is a different
ad-hoc identity and the Keychain ACL does not carry over. The script tells you
how to create the one-time `hudson-dev` self-signed certificate if you do not
have one.

**A test hangs** — you probably called `Runtime.bootstrap()` in a test, which
reaches the real Keychain and may block on a prompt. Use `LocalRuntime` with
an in-memory database, or inject `InMemoryTokenStore`.

**Output looks mangled with a weird email** — you skipped
`Sanitizer.terminalSafe`. That is the bug it exists to prevent.

## See also

- [HudsonCLI reference](../reference/hudson-cli.md)
- [Store reference](../reference/store.md) — what local commands query
- [swift-argument-parser docs](https://github.com/apple/swift-argument-parser/tree/main/Documentation)
